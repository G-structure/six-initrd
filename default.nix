{ lib ? pkgsForBuild.lib
, pkgsForHost
, pkgsForBuild
}:

let
  minimal = lib.makeOverridable (import ./minimal.nix) { inherit lib pkgsForHost pkgsForBuild; };
in {
  inherit minimal;
}

