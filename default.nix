{ lib ? pkgs.lib
, pkgs
}:

let
  minimal = lib.makeOverridable (import ./minimal.nix) { inherit lib pkgs; };
  abduco = lib.makeOverridable (import ./abduco.nix) { inherit lib pkgs; };
in {
  inherit minimal abduco;
}

