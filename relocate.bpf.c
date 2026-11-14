// SPDX-License-Identifier: GPL-2.0-only
/* Linux 7.3+ binfmt_misc handler. No script bytes are modified. */
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#define PATH_SIZE 4096
#define HEADER_SIZE 256
#define ENOEXEC 8
#define ENOMEM 12
#define ENAMETOOLONG 36

extern int bpf_path_d_path(const struct path *path, char *buf,
                          size_t buf__sz) __ksym;
extern int bpf_binprm_set_interp(struct linux_binprm *bprm, const char *path,
                               size_t path__sz) __ksym;
extern int bpf_binprm_set_interp_arg(struct linux_binprm *bprm, const char *arg,
                                   size_t arg__sz) __ksym;

struct scratch {
    char line[HEADER_SIZE];
    char interp[HEADER_SIZE];
    char arg[HEADER_SIZE];
    char path[PATH_SIZE];
};

/* Sleepable programs may migrate CPUs; per-CPU storage is not safe here. */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 512);
    __type(key, __u64);
    __type(value, struct scratch);
} scratch_map SEC(".maps");
static const struct scratch empty;

static __always_inline bool blank(char c)
{
    return c == ' ' || c == '\t';
}

static __always_inline bool nix32(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'd') ||
           (c >= 'f' && c <= 'h') || (c >= 'i' && c <= 'n') ||
           (c >= 'p' && c <= 's') || (c >= 'v' && c <= 'z');
}

/* A store component begins with /nix/store/<32 nix32 characters>-<name>.
 * The caller supplies a buffer with at least 45 accessible bytes. */
static __always_inline bool store_prefix(const char *p)
{
    if (p[0] != '/' || p[1] != 'n' || p[2] != 'i' || p[3] != 'x' ||
        p[4] != '/' || p[5] != 's' || p[6] != 't' || p[7] != 'o' ||
        p[8] != 'r' || p[9] != 'e' || p[10] != '/')
        return false;
#pragma clang loop unroll(full)
    for (int i = 11; i < 43; i++)
        if (!nix32(p[i]))
            return false;
    return p[43] == '-' && p[44] != '\0' && p[44] != '/' &&
           p[44] != '\n' && !blank(p[44]);
}

static __always_inline struct scratch *acquire(__u64 id)
{
    if (bpf_map_update_elem(&scratch_map, &id, &empty, BPF_NOEXIST))
        return NULL;
    return bpf_map_lookup_elem(&scratch_map, &id);
}

/* Parse exactly the first line, retaining Linux's single optional argument.
 * Reject an unterminated/truncated line rather than selecting a partial path. */
static __always_inline int parse(struct linux_binprm *bprm, struct scratch *s)
{
    int i;
    __u32 end = 0, split = 0, arg = 0;
#pragma clang loop unroll(full)
    for (int j = 0; j < HEADER_SIZE; j++)
        s->line[j] = bprm->buf[j];
    if (s->line[0] != '#' || s->line[1] != '!' || !store_prefix(s->line + 2))
        return -ENOEXEC;
    bpf_for(i, 2, HEADER_SIZE) {
        char c = s->line[i];
        if (c == '\n' || c == '\0') {
            end = i;
            break;
        }
        if (!split && blank(c))
            split = i;
    }
    if (!end)
        return -ENOEXEC;
    if (!split)
        split = end;
    bpf_for(i, 2, HEADER_SIZE) {
        if (i >= split)
            break;
        s->interp[(i - 2) & 255] = s->line[i];
    }
    bpf_for(i, 0, HEADER_SIZE) {
        if (end <= split || !blank(s->line[(end - 1) & 255]))
            break;
        end--;
    }
    bpf_for(i, 0, HEADER_SIZE) {
        if (split >= end || !blank(s->line[split & 255]))
            break;
        split++;
    }
    bpf_for(i, 0, HEADER_SIZE) {
        __u32 pos = split + i;
        if (pos >= end || pos >= HEADER_SIZE)
            break;
        s->arg[i] = s->line[pos];
        arg = i + 1;
    }
    s->arg[arg & 255] = '\0';
    return 0;
}

/* Return the offset of the first relocated store component. d_path resolves
 * symlinks and relative exec paths in the executing task's mount namespace. */
static __always_inline int root_offset(struct linux_binprm *bprm, struct scratch *s)
{
    int i, len = bpf_path_d_path(&bprm->file->f_path, s->path, sizeof(s->path));
    if (len <= 0 || len > PATH_SIZE || s->path[0] != '/')
        return -ENOEXEC;
    if (store_prefix(s->path))
        return -ENOEXEC;
    bpf_for(i, 1, PATH_SIZE - 44) {
        if (i + 44 >= len)
            break;
        if (store_prefix(s->path + i))
            return i;
    }
    return -ENOEXEC;
}

SEC("struct_ops.s/match")
bool BPF_PROG(relocated_match, struct linux_binprm *bprm)
{
    __u64 id = bpf_get_current_pid_tgid();
    struct scratch *s;
    bool ours;
    if (bprm->buf[0] != '#' || bprm->buf[1] != '!')
        return false;
    s = acquire(id);
    if (!s)
        return false;
    ours = !parse(bprm, s) && root_offset(bprm, s) > 0;
    bpf_map_delete_elem(&scratch_map, &id);
    return ours;
}

SEC("struct_ops.s/load")
int BPF_PROG(relocated_load, struct linux_binprm *bprm)
{
    __u64 id = bpf_get_current_pid_tgid();
    struct scratch *s = acquire(id);
    int ret, root, i;
    bool terminated = false;
    if (!s)
        return -ENOMEM;
    ret = parse(bprm, s);
    if (ret)
        goto out;
    root = root_offset(bprm, s);
    ret = root;
    if (root <= 0)
        goto out;
    bpf_for(i, 0, HEADER_SIZE) {
        __u32 dest = root + i;
        if (dest >= PATH_SIZE)
            break;
        s->path[dest] = s->interp[i];
        if (!s->interp[i]) {
            terminated = true;
            break;
        }
    }
    ret = -ENAMETOOLONG;
    if (!terminated)
        goto out;
    ret = bpf_binprm_set_interp(bprm, s->path, sizeof(s->path));
    if (!ret && s->arg[0])
        ret = bpf_binprm_set_interp_arg(bprm, s->arg, sizeof(s->arg));
out:
    bpf_map_delete_elem(&scratch_map, &id);
    return ret;
}

SEC(".struct_ops.link")
struct binfmt_misc_ops nix_relocated = {
    .match = (void *)relocated_match,
    .load = (void *)relocated_load,
    .name = "nix_relocated",
};
char _license[] SEC("license") = "GPL";
