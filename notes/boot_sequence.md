# OS Initialization 

The InitOS project is focused on safe initialization of a physical machine. It consists on one EFI file, containing a 'UKI' - linux
kernel, initrd and CLI args.

There are 2 variants - a simple one intended as replacement for 
grub + dracut (and other equivalents), and one for secure boot.

The main difference is that the boot components should be built in a secure, isolated environment - and not on each machine. 

It also tries to keep things as small and simple (readable) as possible, with all logic around boot in a single shell script.

## Simple boot (insecure)

The simple boot is similar to grub - secure boot is not used and
the root disk is not encrypted. That means someone with access to
the hardware can replace the boot or change the disk. It is  
fine for test machines - and even for personal cheap servers, that's
how majority of linux distributions using grub actually work.

The init script detects insecure boot from the EFI variables, and 
mounts an EXT4 disk with label 'STATE' as /z (this is used to allow 
coexistence with ChromiumOS - this is the main disk).

On the disk, either /z/rootfs/etc or /z/etc must exist - they are 
given control after initialization. The rootfs is expected to have the kernel and matching modules installed - but not grub or dracut.

Since physical access to the machine would allow root anyways - a shell on the console is possible.

The script will also attempt to use some of the 'secure boot' 
elements: if /z/initos/BOOTA/initos.hash is present and matches the EFI - it is mounted and used. Same for the sidecar.hash. 

The 'initos.sqfs' is an image containing the kernel modules and firmware. It should be installed at the same time with the EFI -
and not require the rootfs to include the same.

The sidecar.sqfs contains an Alpine-based sidecar that can build
the EFI and perform secure boot, along with many utilities. It is
mounted as /initos/sidecar - and can be used with chroot or as a container.

## Secure boot sequence

This requires a central machine to build and sign the EFI.

The keys are copied and most be installed in the BIOS, and secure boot enabled - this is manual on each machine.

The central machine also adds the 'mesh' root public keys and
any configs - it can build a single image or one image per machine
or group of machines, with machine-specific configs.

1. EFI loads the UKI image (kernel + initramfs + cmdline). This should be signed and contain root public keys and mesh-specific core configs. 

2. If boot was secure, look for initos rootfs (containing modules/firmware) and sidecar (alpine). Both are verity-mounted, using hashes built into the UKI image. Pass control to sidecar. Any error is fatal, reboot.

We copy the /local dir from UKI and the current startup scripts, it  contains signed configs (CA root, etc) and give control to  initios-init script in the rootfs.

## Sidecar behavior

The InitOS image is an alpine image with a custom init script responsible for further machine initialization:

- load kernel modules, start udev, initialize hardware

- unlock the TPM2 and get the LUKS key, or ask the user for the key

- use the key to mount the LUKS partition

Based on the (signed in the UKI or encrypted in LUKS) configurations, it may:

- switch root to one of the 'rootfs' subvolumes on the encrypted disk. If the rootfs is not using systemd, InitOS will continue to run as a sidecar - mainly the SSHD and udev handling.

- continue running, start one or more pods and VMs using rootfs and images on the disk


## Disk layout 

For safe upgrade, a dual EFI layout is used, with a BOOTA and BOOTB
partition, similar to ChromeOS (which has 2 kernel/root partitions - no EFI normally).

On upgrade, the alternate partition gets the new version and is set
as 'next boot'. If the startup works, the boot order is changed, otherwise on reboot the old partition is used.

Common use cases:
- 2 or more NVME (servers): BOOTA and BOOTB should be on different disks.
- 1 NVME (modern laptops): first 2 partitions (or A odd, B even)
- mmc, sda, USB recovery - old laptops with smaller disks: can use single BOOTA parititon. On failure recovery from USB.

Need at least 500M for each. 

Each EFI partition has a vfat label: BOOTA and BOOTB, BOOTUSB

Each EFI partition has the initios directory containing the EFI files and images.
The EFI/BOOT/BOOTx64.EFI file is usually the USB/recovery image, not signed.

The disks may include one or multiple LUKS partitions containing a BTRFS filesystem (for multi-disk, raid1).

The BTRFS is mounted under /x - and /x/initos/env is used to determine which rootfs to switch to (if any) and
what VMs and containers to start.

It also holds:
  - @home, @log, @cache, images/ subvolumes
  - @cache/docker - for the /var/lib/docker
  - swap

Optional: LVM partition for the use with VMs.

# USB Disk layout

- EFI partition, label BOOTUSB containing the InitOS files (same as usual)
  - initos/KEYS will be used to setup secure boot
  - initos/install/ scripts will be run automatically to unatended installs.
- optional LUKS disk containing a btrfs filesystem - can be copied over to the host disk.


# Rootfs (full)

A 'full' rootfs includes an init - openrc, sysv or systemd (not recommended but works).
`setup-deb install-init` should add the required packages.

# Rootfs (OCI/container)

The goal is to use plain OCI images as rootfs - without init or 'host' packages. To support this, 
the recovery disk will be run first and will handle init and hardware.

