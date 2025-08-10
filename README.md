# OS initialization


The goal is to simplify and secure the physical machine startup, replacing Grub and usual Initrd(dracut, etc) with a SIGNED and customized UKI EFI file that will directly boot.

Target is a modern machine with TPM2 and EFI secure boot support, with the
goal of having SIMPLE and inspectable boot process with as little features
or options as possible.

The core features and unerlying implementation are:
- signed and personalized UKI-EFI - without any other bootloader or intermediary, and including user-specific roots and configs.
- central build and update for the fleet - individual hosts can't sign or modify the boot process.
- dm-verity-signed 'host sidecar', in a sqfs file
- TPM.2 storage for the disk and ssh keys for servers
- LUKS encrypted disk for user data and secrets
- optional unencrypted partition for signed images, encrypted backups, etc.

At the end of the boot sequence control is passed to the user rootfs, which
can be any linux variant, including images extracted from container images.
It can either switch root - or run (one or more) OSes in containers of VMs.

For the cases where systemd is used - the components dealing with disk or
network need to be disabled - the sidecar is responsible for this. Ideally
any systemd OS will be run in a VM. The rootfs does not need to include
a kernel image, firmware or any of the components to deal with network or
storage.

The result is a separation between 'host' - kernel, firmware, storage 
encryption, network - and 'rootfs', which has an environment similar to 
a container or light VM even if it runs directly on host.

## UKI EFI 

"Unified kernel image" includes an EFI stub, kernel, command line and initrd. Inside initrd we can add user-specific root keys and configs 
before signing on a 'host control plane' VM, which is the only place
where the signing private keys should be present.

The stub is a forked and simplified version of gummyboot - included in this
repo (upstream is abandoned). There is a systemd stub - but far more complex and it didn't work on all my machines - and conflicts with the 
goal of having understandable code for the entire process.

Signing and optional clean build of the image should only be done on a secure machine ('host control plane') - the result is distributed to all other machines. With the exception of the secure build machine - no host should be able to generate modified UKI or sidecar image. The host control plane can sign host-specific uki.efi images, with specific bootstrap scripts and options - or generic ones
that work with any host.

 The 'verified' mode is enabled by installing the (user specific) signing keys and setting secure boot enabled. It is also possible to use in 'unverified' mode - on machines without TPM2 or secure boot, equivalent to a typical linux distribution where anyone with access to a host can take control and modify it.

## Host sidecar

The UKI.EFI will verify integrity of the image using a hash built into the
customised initrd, along with the public keys of the user and custom authorzed_keys.

The sidecar role is to handle all disk and network initialization - and
will run a ssh server configured to allow the host control plane to control
upgrade and the machine behavior.

If secure boot is enabled - it will attempt to unlock a TPM - based on a config stored under /z/initos/tpm_handle, for servers - or will ask 
for a password and use it to unlock the LUKS partitions and mount the
result under "/x".

If secure boot is disabled - it will just boot and pass control to a startup script under /z/initos/startup.

# OS installation

On the secure machine, run:

`docker run -v $(pwd):/out -v ${SECRETS}:/var/run/secrets  REPO/sidecar:latest setup-efi`

It will create a directory "efi" containing all the files necessary
to copy on a USB EFI partition.

Boot a host using the USB disk - or copy the files to a new or existing
EFI partition on the target host, and reboot selecting the new EFI disk.



## Partitions

- 2 500M EFI partitions (for A/B). 1 is possible too with recovery from USB.
- 1 LUKS partition for the user data and secrets. 

For systems with 2 or more disks, each disk should have
an EFI and 1 LUKS for the rootfs.


# Background


The main reason for writing this is that I got too frustrated with having to deal with Grub and Dracut and the general model of Linux booting - where each machine has to create its own init image that only work on that machine. Security is so complicated and likely to fail that few bother - and the fundamental design of having each host deal with signing and 
building the boot image is IMO fundamentally flawed. 

Android, ChromeOS, COS and many other Linux systems exist where you don't need to do this dance - more secure and reliable. 
Unfortunately ChromeOS Flex does not have a 'server' variant that is easy to install and run containers of VMs (COS and few others exist - but are not easy to install, or too large).

# Rootfs and 'boot' isolation

Thanks to containers, most Linux distributions work with a different kernel, provided by the host. There is no longer a reason to use the exact same distro for boot/kernel/modules as the rest of the OS - and quite a few examples that allow multiple distributions on the same machine.

The goal is to build the rootfs as a container, test it - and deploy it
to hosts. In most cases it can continue to be run as a container or VM - in 
rare cases it will be run as the 'main' operating system, but without dealing with the storage/networking/kernel which are handled by the host sidecar.


# UKI and 'image'-based install

There is no reason to use a OS installer that is based on ISO images, ancient hardware and is installed by installing and running 100s of packages to create exactly the same thing that an image provides ( or worse ).

The fundamental flaw in Linux distributions is that each package:
- installs by running as root a bunch of scripts that may or may not be trustworthy
- the scripts are in many cases tied to a specific machine, and unfriendly to read-only or shared root filesystems.

In this day and age - running as root scripts written by random people on my main machine is not acceptable for me, in particular when it is combined with the attrocious experience of running a duplicated OS (grub) with different behavior if something goes wrong.

I am still using Debian (and sometimes Arch and Alpine) - but the image is built in a container, saved as a docker image that can run anywhere - and that's what will also be 'installed' on a 'raw' hardware, by exporting the OCI image.


