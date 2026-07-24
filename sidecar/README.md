# Sidecar 

The sidecar will generate an erofs/OCI/nar image that should run alongside - not as a daemon but as binaries
that may be started on demand. This includes signing and install scripts, the compiled Nvidia binaries which are tied to the kernel version.

Install (setup-initos-host, setup-deb) is WIP - I still do many steps manually. I am starting to move away from debian,
so the later may be removed.

Few scripts are used for recovery - initos-initrd is called in case of errors in initrd in unlocked mode, initos-init 
as a fallback/default for rootfs that doesn't have any other init.

## Execution environment

The sidecar expects /opt/busybox and /opt/initos to be configured - binaries are statically linked so no other deps.

For initos-initrd - the 2 directories will be in initrd, and depending on stage the STATE ext4 disk may be mounted as /z,
and the ecrypt-fs dir on /z/c. It provides a shell - exiting the shell will continue the boot process.

`initos-init` has a number of functions that duplicate the rust binary - was used before moving the boot to rust and may
be used for recovery and dev. It expects to be run as PID 1 after the switch_root, with /z and /z/c mounted/unlocked.

`setup-initos-host` also expects to run on the host as root, include partitioning and setup functions - this will become the installer.

`sign.sh` can run in an unpriviledged container or as a regular user - it will generate signing keys (if needed) and the
signed boot image, and sign modules, firmware and other 'erofs' images with the 'db' keys. The generated image should
be deployed on other machines - except the secure signing machine all other machines should never have the keys or use this script.

## Deprecated

setup-deb - switching to Nix... May keep it for testing debian still works.

initos-init-qemu - mainly used for testing, may move to tests/ dir but it may also be useful.





