{
  description = "six-initrd – light-weight initramfs builder (flake wrapper)";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      overlay = final: prev: {
        sixInitrd = import ./default.nix { lib = final.lib; pkgs = final; };
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        # Skip non-Linux systems early to avoid evaluation errors on e.g. Darwin
        supported = builtins.match ".*-linux" system != null;
        pkgs = import nixpkgs {
          inherit system;
          overlays = [];
        };
        six = import ./default.nix { inherit (pkgs) lib; inherit pkgs; };
      in
      if supported then {
        # 1. Expose the plain derivation (uncompressed cpio)
        packages = {
          minimal = six.minimal;
          # Handy variant: gzip-compressed initramfs
          minimal-gz = six.minimal.override { compress = "gzip"; };
        };

        # 2. Library output for helpers like `abduco`
        lib = six // { inherit (six) minimal abduco; };

        # 3. Trivial check: build once in CI
        checks.build = self.packages.${system}.minimal;

        # 4. Development shell with formatter and just
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ just nixpkgs-fmt ];
          shellHook = "just --list || true";
        };

        formatter = pkgs.nixpkgs-fmt;
      } else {}
    ) // {
      overlays.default = overlay;
    };
} 