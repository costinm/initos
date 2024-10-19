# OS init and recovery

This project creates OCI image (costinm/recovery:latest) based on Alpine linux, with
all the tools needed to build a signed UKI kernel.efi image and dm-verify signed squash fs.



TODO: how to quickly setup a USB disk, generate the signing keys and sign your installer.



# Background


The main reason for writing this is that I got too frustrated with having to deal with 
Grub and Dracut and the general model of Linux booting - where each machine has to 
create its own init image that only work on that machine. 

Android, ChromeOS, COS and many other Linux systems exist where you don't need to do
this crazy dance - and are also more secure and reliable. Unfortunately ChromeOS Flex
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


