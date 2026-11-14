{ pkgs }:
let
  # Script fixtures and their complete closure.
  bash = pkgs.pkgsStatic.bash;

  hello = pkgs.writeScript "hello" ''
    #!${bash}/bin/bash
    echo "Hello world!"
  '';

  arguments = pkgs.writeScript "arguments" ''
    #!${bash}/bin/bash -eu
    printf '%s\n' "$0" "$@"
  '';

  errexit = pkgs.writeScript "errexit" ''
    #!${bash}/bin/bash -e
    false
    echo "The shebang argument was lost"
  '';

  interpreter = pkgs.writeScript "interpreter" ''
    #!${bash}/bin/bash
    printf '%s\n' "$BASH"
  '';

  closure = pkgs.closureInfo {
    rootPaths = [
      hello
      arguments
      errexit
      interpreter
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "relocatable-shebang";

  # VM configuration: keep the handler stopped until the baseline is checked.
  nodes.machine = { lib, ... }: {
    imports = [ ./module.nix ];
    boot.kernelPackages = pkgs.linuxPackages_latest;
    boot.binfmt.relocatableShebang.enable = true;

    systemd.services.relocatable-shebang.wantedBy = lib.mkForce [ ];

    environment.systemPackages = [
      pkgs.util-linux
      pkgs.python3
    ];
    virtualisation.additionalPaths = [ closure ];
  };

  testScript = ''
    # Setup: boot the VM and copy the closure into a relocated store.
    machine.start()
    machine.succeed("${hello}")
    machine.succeed("mkdir -p /relocated/nix/store")
    machine.succeed("while read -r p; do cp -a \"$p\" /relocated/nix/store/; done < ${closure}/store-paths")

    # Mount namespace helper: hide the original store before executing a file.
    # Python calls execve directly: no shell ENOEXEC fallback can mask a failure.
    machine.succeed("cp ${pkgs.writeText "exec-hidden.py" ''
      import os
      import subprocess
      import sys

      subprocess.run(["mount", "--make-rprivate", "/"], check=True)
      subprocess.run(["mount", "-t", "tmpfs", "tmpfs", "/nix/store"], check=True)
      assert not os.path.exists("${bash}/bin/bash")
      os.execv(sys.argv[1], sys.argv[1:])
    ''} /exec-hidden.py")

    # Baseline: the relocated script cannot find its original interpreter.
    command = "unshare --mount ${pkgs.python3}/bin/python /exec-hidden.py /relocated${hello} 2>&1"
    status, output = machine.execute(command)
    assert status != 0, output
    assert "FileNotFoundError" in output, output

    # Prove that the copied interpreter itself needs no access to /nix/store.
    hidden = "unshare --mount ${pkgs.python3}/bin/python /exec-hidden.py "
    assert machine.succeed(hidden + "/relocated${bash}/bin/bash -c 'echo static'").strip() == "static"

    # Handler enabled: both relocated and original scripts execute successfully.
    machine.succeed("systemctl start relocatable-shebang")
    assert machine.succeed(command).strip() == "Hello world!"
    assert machine.succeed("${hello}").strip() == "Hello world!"

    # Prefer the relocated interpreter even when the original is visible.
    assert machine.succeed("/relocated${interpreter}").strip() == "/relocated${bash}/bin/bash"
    assert machine.succeed("${interpreter}").strip() == "${bash}/bin/bash"

    # Argument handling: preserve script arguments and optional shebang flags.
    arg_path = "/relocated${arguments}"
    assert machine.succeed(hidden + arg_path + " 'two words' tail").splitlines() == [arg_path, "two words", "tail"]
    status, output = machine.execute(hidden + "/relocated${errexit} 2>&1")
    assert status == 1 and not output, (status, output)

    # Path resolution: symlinks and relative paths resolve into the relocated store.
    machine.succeed("ln -s /relocated${hello} /alias")
    assert machine.succeed(hidden + "/alias").strip() == "Hello world!"
    assert machine.succeed("cd /relocated; " + hidden + ".${hello}").strip() == "Hello world!"

    # Matching boundaries: ignore scripts outside a valid relocated store.
    machine.succeed("cp /relocated${hello} /outside-store")
    machine.fail(hidden + "/outside-store")

    # Store hashes are exactly 32 nix32 characters, not arbitrary directory names.
    for bad_hash in ["0" * 31, "0" * 33, "e" * 32, "o" * 32, "t" * 32, "u" * 32, "A" * 32]:
        bad_path = "/relocated/nix/store/" + bad_hash + "-hello"
        machine.succeed("cp /relocated${hello} " + bad_path)
        machine.fail(hidden + bad_path)

    # Shebang validation: reject invalid hashes even if an interpreter exists.
    machine.succeed("cp ${pkgs.writeText "make-invalid.py" ''
      import os
      from pathlib import Path

      root = Path("/relocated/nix/store")
      fixtures = root / ("0" * 32 + "-fixtures")
      fixtures.mkdir()

      for index, bad_hash in enumerate(["0" * 31, "0" * 33, "e" * 32, "o" * 32, "t" * 32, "u" * 32, "A" * 32]):
          name = bad_hash + "-bash"
          os.symlink("/relocated${bash}", root / name)
          script = fixtures / str(index)
          script.write_text("#!/nix/store/" + name + "/bin/bash\necho should-not-run\n")
          script.chmod(0o755)
    ''} /make-invalid.py")
    machine.succeed("${pkgs.python3}/bin/python /make-invalid.py")

    for index in range(7):
        machine.fail(hidden + "/relocated/nix/store/" + "0" * 32 + "-fixtures/" + str(index))

    # Concurrency: simultaneous execs must not share scratch buffers.
    parallel = hidden + "/relocated${bash}/bin/bash -c 'for i in {1..32}; do /relocated${hello} & done; wait'"
    assert machine.succeed(parallel).splitlines() == ["Hello world!"] * 32

    # Relocation again: derive the new prefix after moving the entire closure.
    machine.succeed("mkdir -p /nested; mv /relocated /nested/root")
    moved = command.replace("/relocated", "/nested/root")
    assert machine.succeed(moved).strip() == "Hello world!"

    # Service lifecycle: restore the handler after either service restarts.
    machine.succeed("systemctl restart relocatable-shebang")
    assert machine.succeed(moved).strip() == "Hello world!"

    machine.succeed("systemctl restart systemd-binfmt")
    machine.wait_for_unit("relocatable-shebang.service")
    assert machine.succeed(moved).strip() == "Hello world!"

    # Handler removed: execution fails again with the original store hidden.
    machine.succeed("systemctl stop relocatable-shebang")
    machine.fail(moved)
  '';
}
