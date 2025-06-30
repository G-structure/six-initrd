{
  description = "six-initrd – light-weight initramfs builder (flake wrapper)";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # six-initrd only builds on Linux systems (needs busybox, etc.)
        supported = builtins.match ".*-linux" system != null;
        pkgs = import nixpkgs { inherit system; overlays = []; };
        six = import ./default.nix { inherit (pkgs) lib; inherit pkgs; };
      in
      if supported then {
        # -------------------------------------------------------------------
        # Packages
        # -------------------------------------------------------------------
        packages = {
          # 1. plain, un-compressed CPIO archive
          minimal = six.minimal;

          # 2. convenient variant: gzip-compressed initramfs
          minimal-gz = six.minimal.override { compress = "gzip"; };
        };

        # -------------------------------------------------------------------
        # Overlays
        # -------------------------------------------------------------------
        overlays.default = final: prev: {
          sixInitrd = import ./default.nix { lib = final.lib; pkgs = final; };
        };

        # -------------------------------------------------------------------
        # Library helpers (expose abduco overlay, etc.)
        # -------------------------------------------------------------------
        lib = six // { inherit (six) minimal abduco; };

        # -------------------------------------------------------------------
        # CI / nix flake check – minimal smoke build
        # -------------------------------------------------------------------
        checks.build = self.packages.${system}.minimal;

        # -------------------------------------------------------------------
        # Development conveniences
        # -------------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ just nixpkgs-fmt ];
          shellHook = "just --list || true";
        };

        formatter = pkgs.nixpkgs-fmt;
      } else {
        # Non-Linux systems: return an empty attrset to avoid evaluation errors
      });
} 