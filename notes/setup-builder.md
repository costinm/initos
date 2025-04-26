
Initos consists of a few docker images:
- initos-base - alpine with tools to build the EFI UKI and signed SQFS rootfs
- debian-kernel - debian base with the kernel/modules installed.
- initos - base plus a pre-build initrd, kernel and sqfs image using debian kernel

The 'initos' image purpose is to create an EFI partition consisting of:
- a signed UKI (kernel+initrd) - including root certificates and mesh configs.
- a verity signed SQFS, containing the files in the initos image and kernel modules/firmware 

Unlike a typical distro, the EFI partition is custom build on a separate build server 
and installed using SSH on one or more machines. It is not a general purpuse EFI that
can be downloaded or build locally - the build machine has the private keys to sign,
and the worker machines can't make any changes.

The SQFS image contains the latest debian kernel/modules, plus the alpine base.
It include scripts to use TPM2 or password to unlock a Verity partition, setup
root certs and networking, run a ssh server for admin. 
It is intended as a 'host sidecar' - will remain available on the host.
After initialization, it will either pivot to a rootfs on the encrypted disk or 
run one or more VMs or containers.

The initrd contains only the minimal script and missing modules to verify signature
of the SQFS.


Setup the customized EFI

The setup script will run the initos image with 2 mounted volumes - one holding
the encryption keys and root configuration, and one output directory where the 
EFI files will be generated.

The EFI files can be copied to a USB disk for the initial install or recovery, or
copied using ssh on a machine that already runs Initos ( or other distros if you have
an EFI partition with ~512M space)


