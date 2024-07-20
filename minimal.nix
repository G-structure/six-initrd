{ lib ? pkgs.lib
, pkgs

# In the unlikely event that you don't want busybox in your initrd, set this to
# null.
, busybox ? pkgs.pkgsStatic.busybox

# An attrset containing additional files to include in the initramfs
# image.  Each attrname in this set is a path relative to the root
# of the initramfs (e.g. "bin/signify") and the corresponding value is
# the file to be copied to that location (e.g. "${signify}/bin/signify).
#
# lib.fileset can't represent empty directories, so it is not usable here.
# There are quite a large number of empty directories which, if missing from the
# initrd, will cause a kernel panic (e.g. CONFIG_DEVTMPFS without a `/dev`, or
# attempting to `mount /proc` from `sh -e` as PID 1).
#
# - If the attrvalue is a store path and does NOT have a trailing "/" then both
#   the source and destination are considered to be files; the source will be
#   copied to the destination.  If the source is a symbolic link it will be
#   dereferenced before copying.
#
# - If the attrvalue is a store path and has a trailing "/" then both the source
#   and destination are considered to be directories; the source will be copied
#   recursively, and symbolic links therein will be preserved (i.e. not
#   dereferenced).  See `withBusybox` below for an example.
#
# - If the attrvalue is NOT a store path (i.e. does NOT begin with
#   `builtins.storeDir` which is usually "/nix/store/"), then a symbolic link is
#   created from the attrname to the attrvalue.  For example,
#
#     "usr/bin" = "../bin"
#
#   Will cause the builder to execute (approximately) this command
#
#     ln -s ../bin usr/bin
#
# In all of the above cases: after copying, `chmod -R u+w` is performed, since
# the contents are likely to be coming from /nix/store where Nix clears the u-w
# the contents arebit.
#
, contents ? {}

# cause /usr/{bin,sbin} to be symlinks to /{bin/sbin}
, symlinkUsrToRoot ? true

# cause /sbin to be a symlink to /bin
, symlinkSbinToBin ? true

# a list of paths (relative to ${kernel}/lib/modules/*/kernel) to modules .ko
# files which should be included in the initrd
, modules ? [ ]

# if `modules!=[]`, this should be a derivation from which to copy the kernel
# modules.  Must have attribute `version`.
, kernel ? null

, compress ? false

}:
assert kernel==null && modules != [] -> throw "kernel is required if modules!=[]";

let
  compressor =
    if compress == false
    then "cat"
    else {
      "gzip" = "gzip";
    }.${compress};
  suffix =
    if compress == false
    then ""
    else {
      "gzip" = ".gz";
    }.${compress};
  contents' = (lib.pipe modules [
    (map (m: let name = "${kernel.version}/kernel/${m}";
             in {
               name = "lib/modules/${name}";            # dest
               value = "${kernel}/lib/modules/${name}"; # source
             }))
    lib.listToAttrs
  ]) // lib.optionalAttrs (busybox != null) {
    "bin" = "${busybox}/bin/";
  }  // lib.optionalAttrs symlinkSbinToBin {
    "sbin" = "bin";
  }  // lib.optionalAttrs symlinkUsrToRoot {
    "usr/bin" = "../bin";
    "usr/sbin" = "../sbin";
  } // contents;

in pkgs.pkgsStatic.stdenv.mkDerivation {
  name = "initramfs.cpio${suffix}";
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    mkdir build
    pushd build
    runHook preBuild
  '' + (lib.pipe contents' [
        (lib.mapAttrsToList (dest: src:
          if !(lib.hasPrefix builtins.storeDir src) then ''
            mkdir -p ${lib.escapeShellArg (builtins.dirOf dest)}
            ln -sT ${lib.escapeShellArg src} ${lib.escapeShellArg dest}
          '' else if lib.hasSuffix "/" src then ''
            mkdir -p ${lib.escapeShellArg (builtins.dirOf dest)}
            cp -Tr ${lib.escapeShellArg src} ${lib.escapeShellArg dest}
            chmod -R u+w ${lib.escapeShellArg dest}
          '' else ''
            install -vDT ${lib.escapeShellArg src} ${lib.escapeShellArg dest}
          ''))
        lib.concatStrings
      ]) +
  ''
    runHook postBuild
    popd
  '';

  installPhase = ''
    runHook preInstall
    chmod -R u+w build
    pushd build
    ${pkgs.buildPackages.findutils}/bin/find . \
      | ${pkgs.buildPackages.cpio}/bin/cpio --create -H newc -R +0:+0 \
      | ${compressor} \
      > $out
    popd
    runHook postInstall
  '';

  passthru = {
    inherit modules;
  };
}
