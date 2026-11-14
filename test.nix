{ pkgs }:
let
  hello = pkgs.writeScript "hello" ''
    #!${pkgs.pkgsStatic.bash}/bin/bash
    echo "Hello world!"
  '';
  closure = pkgs.closureInfo { rootPaths = [ hello ]; };
in
pkgs.testers.runNixOSTest {
  name = "relocatable-shebang";
  nodes.machine = {
    environment.systemPackages = [ pkgs.util-linux pkgs.python3 ];
    virtualisation.additionalPaths = [ hello closure ];
  };
  testScript = ''
    machine.start()
    machine.succeed("${hello}")
    machine.succeed("mkdir -p /relocated/nix/store")
    machine.succeed("while read -r p; do cp -a \"$p\" /relocated/nix/store/; done < ${closure}/store-paths")
    # Python calls execve directly: no shell ENOEXEC fallback can mask a failure.
    machine.succeed("cp ${pkgs.writeText "exec-hidden.py" ''
      import os
      import subprocess
      import sys
      subprocess.run(["mount", "--make-rprivate", "/"], check=True)
      subprocess.run(["mount", "-t", "tmpfs", "tmpfs", "/nix/store"], check=True)
      os.execv(sys.argv[1], sys.argv[1:])
    ''} /exec-hidden.py")
    command = "unshare --mount ${pkgs.python3}/bin/python /exec-hidden.py /relocated${hello} 2>&1"
    status, output = machine.execute(command)
    assert status != 0, output
    assert "FileNotFoundError" in output, output
  '';
}
