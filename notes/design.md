# InitOS design

Goals:
- secure boot and recovery
- minimal and simple code that can be reviewed and changed
- secure remote recovery (no console access required)
- support older machines (without TPM2)

## Secure boot

1. Signed UKI (kernel+cmdline+initrd). The signing happens on a 
trusted machine, which also includes root certificates and 
core configs.

2. DM-Verity image, signed on a trusted machine and copied to all
other machines.

3. LUKS encrypted persistent disk. On machines with TPM2, it is automatically unlocked. On machines without TPM2, or if unlock 
fails - a boot option ('c') allows manual unlock, or the machine boots
in 'recovery' mode where it starts sshd and waits for remote unlock.

4. Recovery mode uses only the signed UKI and the DM-Verity SQFS. 
It is entered by boot option ('r'), or if the persistent disk doesn't
include a rootfs.

Secure mode is intended to be used with 'secure boot'. 

On machines that lack secure boot, or if secure boot is disabled - any
attacker can swap the disk or boot from USB with an insecur distro.


## Initrd

Must be absolutely minimal - and can be omitted if the kernel has
the drivers to load the disk and use verity (with a ChromeOS-like
layout using separate partitions for verity).

Using alpine and mkinitfs. Alpine has small footprint, mkinitfs is 
just used to find the dependencies of required kernel modules.

The initrd does not have shell or recovery or any features besides 
finding the InitOS image, verify the Verity signature and pass
control.

In 'usb' mode the image is on a USBBOOT vfat partition (usually the EFI), otherwuse a BOOT vfat partition. 

Included features:
- busybox + musl 
- modules for vfat and disk drivers
- Verity modules and tools.
- additional /opt/initos/local files containing additional configs that are signed and patched onto the InitOS image.

## InitOS image

Using Alpine-based Verifty-signed SQFS - but can also use a
 separate EFI partition with a read-only ext4 or btrfs (with small changes in the scripts).

The image is signed on a trusted machine and copied over to each 
host.

The image is built into the OCI container that handles signing, but
can be extended with additional files as part of the generation.

The root user is locked. The only way to get a shell in secure 
mode is via ssh using the authorized_keys added at image build time.

In 'insecure' mode (if 'secure boot' is disabled or missing) it is 
possible to get a shell with the 'a' boot option, if the user can
unlock the LUKS partition.

In 'usb' mode - user gets a root shell by default.

## Secure recovery

There are few recovery points.

1. InitOS sqfs fails to load. Machine reboots to previous EFI, if that fails - physical access and USB
disk are required.

2. LUKS fails to open (TPM is bad). 
- Physical access to manually unlock LUKS or reinstall.
- server runs without LUKS, using insecure ssh private key. Evil maid can MITM, but remote access to unlock possible.

3. LUKS open - but other problems: InitOS acts as sidecar and has a sshd server, handles network. Evil maid with advanced hardware can still get it.


## Rootfs

The persistent disk is a BTRFS disk on LUKS encrypted partition.
Using BTRFS because it allows integrity checking and snapshots, but
can be replaced with small changes in the scripts.

It is unlocked as 'c' (crypt) and mounted on /x

Inside the persistent disk, the /initos directory holds configs,
overrides (under /initos/local ) and one or more directories 
holding OS images extracted from OCI containers or manually installed.

The initos config determines which OS image is used as sysroot - if any. Based on local config, the InitOS image can just run one or
more images as container, VMs or chroot. 

If one of the images is loaded as sysroot - /sbin/init will be called,
but the InitOS image continues to be mounted and run a SSHD server
and most utils. The image should not include kernel, modules and 
doesn't need most host or networking utils - it starts in a
container-like environment where network and hardware are already managed by the InitOS sidecar.


## OCI builder

InitiOS is distributed as an OCI image that can be used with any 
container runtime. It is based on Alpine (because InitRD and the
signed images are intended to be minimal), but is using debian
kernel and firmware - Alpine can run with almost any kernel. 

The builder operates on 2 volumes - one holding the secrets and one
holding the resulting 'efi' partitions and additional source files.

Part of the OCI image build, the initial unsigned sqfs and initrd are generated, and during signing the verity signature and additional
configs and binaries can be added.

# Why NOT

##  network on the initrd

- hard to secure
- laptops
- larger image
- many drivers

## single EFI

Using multiple EFI because:
- neeed to deal with multi-disk servers anyways
- easier to wipe the disk than deal with errors
- no need to deal with versions in filenames or dirs
- can move them around.

## recovery or other logic in initrd

- initrd can be removed and kernel used directly.
- it's where it's hardest to recover, so simpler is better
- securing the recovery is hard, in particular remote recovery.