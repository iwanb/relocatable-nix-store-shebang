{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.binfmt.relocatableShebang;
  package = pkgs.callPackage ./package.nix {
    inherit (config.boot.kernelPackages) ebpf-headers;
  };
in
{
  options.boot.binfmt.relocatableShebang.enable =
    lib.mkEnableOption "BPF relocation of Nix store shebang interpreters (Linux 7.3+)";

  config = lib.mkIf cfg.enable {
    systemd.additionalUpstreamSystemUnits = [
      "proc-sys-fs-binfmt_misc.automount"
      "proc-sys-fs-binfmt_misc.mount"
      "systemd-binfmt.service"
    ];
    assertions = [
      {
        assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.3";
        message = "Relocatable shebangs require Linux 7.3 or newer.";
      }
    ];
    system.requiredKernelConfig = with config.lib.kernelConfig; [
      (isYes "BINFMT_MISC")
      (isYes "BINFMT_MISC_BPF")
      (isYes "DEBUG_INFO_BTF")
    ];
    systemd.services.relocatable-shebang = {
      description = "Register the relocated Nix store shebang BPF handler";
      wantedBy = [ "multi-user.target" ];
      after = [
        "proc-sys-fs-binfmt_misc.mount"
        "systemd-binfmt.service"
      ];
      requires = [
        "proc-sys-fs-binfmt_misc.mount"
        "systemd-binfmt.service"
      ];
      partOf = [ "systemd-binfmt.service" ];
      path = [
        pkgs.bpftools
        pkgs.util-linux
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # systemd treats bpffs as an API filesystem, without a mount unit.
        mountpoint -q /sys/fs/bpf || mount -t bpf -o nosuid,nodev,noexec bpf /sys/fs/bpf
        mkdir -p /sys/fs/bpf/relocatable-shebang
        if ! bpftool struct_ops register ${package}/lib/bpf/relocate.bpf.o /sys/fs/bpf/relocatable-shebang > /run/relocatable-shebang.log 2>&1; then
          tail -60 /run/relocatable-shebang.log
          exit 1
        fi
        echo ':nix-relocated:B::::nix_relocated:' > /proc/sys/fs/binfmt_misc/register
      '';
      postStop = ''
        if test -e /proc/sys/fs/binfmt_misc/nix-relocated; then
          echo -1 > /proc/sys/fs/binfmt_misc/nix-relocated
        fi
        rm -rf /sys/fs/bpf/relocatable-shebang
      '';
    };
  };
}
