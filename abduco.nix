#
# This is an overlay you can apply to `minimal.nix`; it takes care of all the
# "sharp edges" of PID1 (fixing control-C, setsid, console setup, pid1-exit
# causing reboot, etc).
#
# Example usage:
#
#   six-initrd.minimal.override (six-initrd.abduco {
#     ttys = { tty0 = null; ttyS0 = "115200"; };
#   })
#
# After some setup tasks, PID1 will spawn the `abduco` terminal multiplexor, and
# tie together as many terminals as you like.  I use this terminal for both
# rescue operations as well as to authenticate to and decrypt my boot disk
# (unlike UEFI systems, ownerboot lets you encrypt *the entire disk* rather than
# just certain partitions!)
#
# I find this multiplexed early-getty to be incredibly useful: I can have both a
# serial console as well as a display console (tty0) tied to a single getty
# process.  So if you type on both the tty0 keyboard as well as the serial
# console, both the serial console output and display console will see the same
# keystrokes (merged from both inputs).  This way I can use the more-comfortable
# display console most of the time, but I always have the serial console enabled
# and don't need to take separate steps to "activate" it when things go wrong.
#
# Why not use two separate consoles?  When it is ready to continue booting, the
# initrd PID1 needs to kill all of its child processes before invoking
# switch_root.  If it has two getty child processes it you'll run into problems:
#
# 1. PID1 can't wait for both children to exit, because usually the human only
#    wants to use one of them.  Waiting for either one to exit and then
#    forcefully killing the other one is annoyingly fragile -- I tried this at
#    first, but if anything malfunctions on one of the child gettys, causing it
#    to die, it will take down the other one before the system is ready to boot.
#    It also leads to race conditions -- if you try to run `luksOpen` on two
#    gettys concurently you'll discover all sorts of annoying bugs.
#
# 2. Since PID1 is dealing with two child processes, it needs a proper process
#    supervisor like s6-svscan.  This is a more heavyweight solution than I
#    desire.
#
# It's just much simpler for PID1 to have a single child process which
# multiplexes two terminals.  Since there's only one getty the question of "has
# the getty process exited yet" is unambiguous and simple.
#
# When using this overlay, the early boot process is controlled by three files:
#
#   /early/run    - this will be executed in an abduco session
#   /early/finish - if /early/run exits zero, this will be exec()ed as pid1
#   /early/fail   - if /early/run exits nonzero or any other failure occurs,
#                   this will be exec()ed as pid1
#
# If any of the above files are missing from the initrd they will be populated
# with a script which does `exec /bin/sh`.
#
# You should create your own `/early/run` and include it in the initrd, like this:
#
#   lib.pipe six-initrd.minimal [
#     (initrd: initrd.override (six-initrd.abduco { ttys = ... };))
#     (initrd: initrd.override (previousArgs: {
#       contents = (previousArgs.contents or {}) // {
#         "/early/run" = pkgs.writeScript "early-run.sh" ''
#           #!/bin/sh
#           echo do stuff here
#         '';
#         "/early/finish" = pkgs.writeScript "early-finish.sh" ''
#           #!/bin/sh
#           echo invoke switch_root here
#         '';
#       };
#     }))
#
#
{ lib
, pkgsForBuild
, pkgsForHost
, ttys ? throw "ttys argument is required" # attrset of <ttyname>=<speed>; speed==null is allowed; e.g. { tty0 = null; }
}:

let
  initScript = pkgsForBuild.writeScript "init" (''
    #!/bin/sh
    export PS1=initrd-pid1\#

    # `setsid cttyhack` needs some basic mounts in `/dev`, so we do this first
    echo "init: doing basic mounts"
    mkdir -p /run /dev /dev/pts /sys /proc
    mount  -t proc     none /proc    -o nodev,noexec,nosuid,nofail
    mount  -t sysfs    none /sys     -o nodev,noexec,nosuid,nofail
    mount  -t devtmpfs none /dev     -o nosuid,mode=0755,nofail
    mount  -t devpts   none /dev/pts -o noexec,nosuid,gid=5,mode=0620,nofail
    mount  -t tmpfs    none /run     -o noexec,nosuid,size=10%,mode=0755

    # do a "coldplug" to create any needed device nodes
    busybox mdev -s

    # This if-condition is a somewhat-gross hack; it looks to
    # see if *any* process has a nonzero session id.  We really want to
    # know if *this* process has a nonzero session id, but I
    # don't know of any busybox tool that tells you that directly.
    if !(ps -o sid | grep [1-9] > /dev/null); then
      # see:
      #   https://busybox.net/FAQ.html#job_control
      #   https://www.win.tue.nl/~aeb/linux/lk/lk-10.html#ss10.3
      echo "init: doing ctty hack"
      exec busybox setsid cttyhack $0
      echo "init: `exec setsid cttyhack` exited with an error!"
      exec /bin/sh
    fi

    echo "init: ensuring /early/{fail,run,finish} exist"
    # we can't symlink /early/fail directly to /bin/sh because busybox cares about argv[0]
    echo -e '#!/bin/sh\nexec /bin/sh' > /early/missing
    chmod +x /early/missing
    if [ \! -e /early/fail   ]; then ln -s /early/missing /early/fail;   fi
    if [ \! -e /early/run    ]; then ln -s /early/missing /early/run;    fi
    if [ \! -e /early/finish ]; then ln -s /early/missing /early/finish; fi

    echo "init: starting abduco session"
    mkdir -p /run/abduco

    # here we fork a child and block until it exits
    ABDUCO_SOCKET_DIR=/run/abduco abduco -c init /early/abduco-session.sh || \
      exec /early/fail

    echo "init: abduco /early/run exited; exec()ing into /early/finish"
    exec /early/finish

    # fallthrough in case of exec failure
    echo "init: !BUG! (please report) this line should never execute"
    exec /early/fail
  '');

  abduco-session-sh = let
    setup-ttys = lib.concatStrings (lib.mapAttrsToList (tty: speed: ''
      export PS1=initrd-abduco\#
      echo "init: setting up tty for /dev/${tty}"
      stty -F /dev/${tty} sane
    '' + lib.optionalString (speed != null) ''
      stty -F /dev/${tty} speed ${toString speed} > /dev/null
    '' + ''
      echo "init: attaching abduco client on /dev/${tty}"
      abduco -a init < /dev/${tty} > /dev/${tty} 2>&1 &
    '') ttys);
  in pkgsForBuild.writeScript "abduco-session.sh" (''
    #!/bin/sh
    echo "init: in abduco session"
    ${setup-ttys}
    echo "init: running /early/run inside abduco session"
    /early/run || exit $? # not exec()ed due to possible abduco bug (console flood)
    exit 0
  '');
in previousArgs: {
  contents = (previousArgs.contents or {}) // {
    "init" = "/early/init";
    "bin/abduco" = "${pkgsForHost.pkgsStatic.abduco}/bin/abduco";
    "early/init" = "${initScript}";
    "early/missing" = pkgsForBuild.writeScript "missing.sh" ''
      #!/bin/sh
      export PS1=initrd-$(basename $0)-pid1\#
      exec /bin/sh
    '';
    "early/abduco-session.sh" = "${abduco-session-sh}";
    "etc/fstab" = builtins.toFile "fstab" ''
    '';
  };
}

