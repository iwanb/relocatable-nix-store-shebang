# Relocatable Nix shebangs

Make scripts with hardcoded `/nix/store/` shebang paths relocatable without
changing the scripts. After copying a script and its closure beneath another
root, the [binfmt handler](relocate.bpf.c) selects the interpreter from that
relocated store at execution time. For example, a script under
`/opt/app/nix/store/` whose shebang names `/nix/store/<hash>-bash/bin/bash` runs with
`/opt/app/nix/store/<hash>-bash/bin/bash`.

It triggers only when the script's resolved path matches
`<other-root>/nix/store/<hash>-...` and its shebang starts with
`#!/nix/store/<hash>-...`, where each hash is 32 nix32 characters.
Scripts in the original `/nix/store/` or outside a relocated store are unaffected.

# Implementation

```sh
nix-build
```

`default.nix` imports `<nixpkgs>` and calls `test.nix { pkgs = ...; }`.
The test boots Linux 7.3+, copies a script's closure beneath another root,
hides `/nix/store` in a private mount namespace, and demonstrates the missing
interpreter before loading the handler. It uses statically linked Bash so
that ELF loader and shared-library relocation are independent of this test.

To enable the handler on NixOS:

```nix
{
  imports = [ ./module.nix ];
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.binfmt.relocatableShebang.enable = true;
}
```

Linux 7.3 or newer with `CONFIG_BINFMT_MISC_BPF=y` and kernel BTF is required.
The BPF object is compiled against the selected kernel's BTF and registered
by `relocatable-shebang.service`.

The handler accepts a first line beginning exactly with
`#!/nix/store/<32 nix32 characters>-<name>`. If the resolved script path is
`<root>/nix/store/<32 nix32 characters>-<name>...`, it selects the shebang
interpreter under `<root>` and preserves the optional shebang argument.
The script and interpreter hashes can differ. Scripts in the real
`/nix/store` and scripts outside a relocated store retain normal kernel
handling. Symlinks and relative execution paths use the resolved file path;
if it contains multiple qualifying store components, the first wins.

No file contents change and no second-line annotation is needed. The selected
interpreter must exist under the relocated root. Dynamic interpreters still
need their own ELF loader and library paths to work there; this handler only
relocates script interpreters. The copied closure's embedded absolute paths
to other programs or data are also unchanged.

Implementation follows the sleepable `binfmt_misc_ops` pattern used by
[nixpkgs PR #587965](https://github.com/NixOS/nixpkgs/pull/587965) and the
[kernel binfmt documentation](https://docs.kernel.org/admin-guide/binfmt-misc.html).
Scratch buffers are keyed by task ID because sleepable BPF programs can
migrate between CPUs. At most 512 simultaneous handler invocations have
scratch slots; allocation failure during matching declines the handler.
This can silently fall back to the original `/nix/store` interpreter if it is
available, rather than the relocated interpreter. A production implementation
would need to handle this case explicitly so that resource exhaustion cannot
silently change which interpreter runs.
