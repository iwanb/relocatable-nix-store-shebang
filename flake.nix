{
  description = "BPF relocation of Nix store shebang interpreters";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      checks = nixpkgs.lib.genAttrs systems (system: {
        relocatable-shebang = import ./test.nix {
          pkgs = import nixpkgs { inherit system; };
        };
      });
    };
}
