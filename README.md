# OS initialization

The goal is to simplify and secure the physical machine startup, replacing Grub and usual Initrd(dracut, etc) with a signed UKI EFI file that will directly boot.

Target is a modern machine with TPM2 and EFI secure boot support. 

Unlike typical distros, the kernel, initrd and UKI are build and signed on a separate trusted machine. A normal host will not mess with the kernel/initrd or signing keys. 

The control plane will also manage the upgrade process
for the kernel/modules/boot environment.

The small initrd included in the UKI will have minimal
responsibilities:

- use dm-verity to mount modules/firmware from a sqfs file (which also includes recovery/install image).
- attempt to use TPM2 to unlock the primary LUKS volume
- it expects a btrfs FS (can be swapped but I'm happy with it - main reason is 'reflink' and mountable subvols)
- based on a config on the encrypted disk, mount a subvol as root filesystem and pass control to it.

The initrd SHOULD NOT provide root shell - the bootloader is expected to be locked. All admin, 
recovery or install should be done by the control plane, over ssh.

Most operating systems that work in containers will
also work here - like containers, the kernel and 
modules are 'external'.

# OS installation

A special USB build of InitOS is intended for install.

The main change is that it does not mount the btrfs
and it has a root shell and may run a script that doees
unatended install or recovery. 

## Partitions

- 2 500M EFI partitions (for A/B). 1 is possible too with recovery from USB.
- 1 LUKS partition for the system. 

For systems with 2 or more disks, each disk should have
an EFI and 1 LUKS for the rootfs.



With a pair of ~500M EFI partitions taking care of kernel/initrd, the next goal is to make it easier to install the OS.

The expectation is that the rootfs will be created using docker or equivalent tools, as a OCI image.

InitOS includes helpers to pull an OCI image and copy it to a
btrfs subvolume. Multiple such volumes can be created - and one is selected as host root, while the others can be used in
containers or VMs (using virtiofs).

This project creates a number of host OCI images, i.e. including kernel/modules/firmware:
- 'debianhost' - Debian based rootfs for a raw machine. 
- 'alpinehost' - Alpine with all the tools to create the EFI files, including kernel and firmware.

It also creates 'normal' container:
- debianui - Debian + KasmVNC - I'm using it for remote dev.

For both 'host' images I'm using the debian kernel, with nvidia
drivers included - since it's what I use. It is not meant 
as something anyone can use, with a bloated set of software based on my preferences - but as something anyone can build
with the image content they want. 


# Background


The main reason for writing this is that I got too frustrated with having to deal with 
Grub and Dracut and the general model of Linux booting - where each machine has to 
create its own init image that only work on that machine. 

Android, ChromeOS, COS and many other Linux systems exist where you don't need to do
this dance - and are also more secure and reliable. 

Unfortunately ChromeOS Flex
does not have a 'server' variant that is easy to install and run containers of VMs (COS
and few others exist - but are not easy to install, or too bloated).

# Rootfs and 'boot' isolation

Thanks to containers, most Linux distributions work with a different kernel, provided
by the host. There is no longer a reason to use the exact same distro for boot/kernel/modules as the rest of the OS - and quite a few examples that allow
multiple distributions on the same machine.

# UKI and 'image'-based install

There is no reason to use a OS installer that is based on ISO images, ancient hardware
and is installed by installing and running 100s of packages to create exactly the same
thing that an image provides ( or worse ).

The fundamental flaw in Linux distributions is that each package:
- installs by running as root a bunch of scripts that may or may not be trustworthy
- the scripts are in many cases tied to a specific machine, and unfriendly to read-only or shared root filesystems.

In this day and age - running as root scripts written by random people on my main
machine is not acceptable for me, in particular when it is combined with the attrocious
experience of running a duplicated OS (grub) with different behavior if something
goes wrong.

I am still using Debian (and sometimes Arch and Alpine) - but the image is built
in a container, saved as a docker image that can run anywhere - and that's what
will also be 'installed' on a 'raw' hardware, by exporting the OCI image.

Modules, firmware and recovery will be split - for now using dm-verity signed 
squashfs files on the EFI partition, may move them to BTRFS subvolumes later.


