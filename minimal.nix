{ lib
, pkgsForHost
, pkgsForBuild

# In the unlikely event that you don't want busybox in your initrd, set this to
# null.
, busybox ? pkgsForHost.pkgsStatic.busybox

# An attrset containing additional files to include in the initramfs
# image.  Each attrname in this set is a path relative to the root
# of the initramfs (e.g. "bin/signify") and the corresponding value is
# the file to be copied to that location (e.g. "${signify}/bin/signify).
#
# - If the attrvalue has a trailing "/" then both the source and
#   destination are considered to be directories; the source will be
#   copied recursively, and symbolic links therein will be preserved
#   (i.e. not dereferenced).  See `withBusybox` below for an example.
#
# - If the attrvalue does NOT have a trailing "/" then both the
#   source and destination are considered to be files.  If the
#   source is a symbolic link it will be dereferenced before copying.
#
# After copying, `chmod -R u+w` is performed, since the contents are
# likely to be coming from /nix/store where Nix clears the u-w bit.
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
  } // contents;

in pkgsForHost.pkgsStatic.stdenv.mkDerivation {
  name = "initramfs.cpio${suffix}";
  dontUnpack = true;
  dontFixup = true;

  buildPhase = ''
    mkdir build
    pushd build
    runHook preBuild
  '' + lib.optionalString symlinkSbinToBin ''
    ln -s bin sbin
  '' + lib.optionalString symlinkUsrToRoot ''
    mkdir -p usr
    ln -s ../bin usr/bin
    ln -s ../sbin usr/sbin
  '' + (lib.pipe contents' [
        (lib.mapAttrsToList (dest: src:
          if lib.hasSuffix "/" src then ''
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
    ${pkgsForBuild.findutils}/bin/find . \
      | ${pkgsForBuild.cpio}/bin/cpio --create -H newc -R +0:+0 \
      | ${compressor} \
      > $out
    popd
    runHook postInstall
  '';

  passthru = {
    inherit modules;
  };
}
