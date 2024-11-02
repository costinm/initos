# Disk layout 

- EFI partition, containing:
  - the signed UKI kernel image as BOOTx64.EFI
- second EFI partition label, with a different version
- a btrfs filesystem named BTRFS_BOOT containing
  - a directory named /initos
    - firmware.sqfs 
    - modules-VERSION.sqfs for each version
    - recovery.sqfs
    - additional kernel, initrd, modules for virtual machine
    - verity images for each sqfs. The initramfs contains the hash of each verity image.
- multiple LUKS partitions containing a BTRFS filesystem (for multi-disk, raid1)
  - one or more rootfs subvolumes - /root-NAME
  - @home, @log, @cache subvolumes
  - docker - for the /var/lib/docker
  - swap
- optional: raid0 multi-disk BTRFS 'WORK' for work files, images, models, etc (only public data)
- optional: LVM partition for the use with VMs.

# USB Disk layout

- EFI partition, label USB_BOOT, containing 
  - unsigned UKI as BOOTx64.EFI - with root terminal and options to enter debug mode
  - signed UKI
  - all the files under initos/ directory - will be copied over BTRFS_BOOT on disk
  - hosts/ directory, with subdirs named based on the MAC address and non-confidential configs.
- optional USB_DATA LUKS disk containing a btrfs filesystem - can be copied over to the host disk.
- optional USB_BACKUP btrfs regular disk - encrypted (restic).


# Default boot sequence (secure mode)

1. EFI loads the signed UKI image
2. kernel inits and load the bundled initramfs
3. the custom /init script starts as user 1
4. the script checks it is running as user 1, start the init sequence
5. init basic filesystem and mount /proc, /sys, etc (initramfs_1st, mount_proc)
6. load the simpledrm module (to show info on the display) or equivalent
7. load additional modules common for finding the disk (initramfs_mods)
8. start udevd, wait for it to settle. While waiting - read a key to use manual unlock.
9. locate BOOT partition and mount it as btrfs.
   - if USB_BOOT is found - it will be used instead, as vfat.
10. mount recovery, modules and firmaware sqfs and overlay - using dm-verifty with hash from 
  the signed initramfs /boot/sign/
11. run TPM commands to unlock the LUKS partition. If 'c' was typed - use manual unlock.
12. once the LUKS is unlocked, mount the rootfs and switch to it - using a config file 
  under /initos/ subvolume.
13. In case of failure - switch root to the recovery disk, or reboot (no recovery shell).

Including tpm2 and all related modules on initramfs is tricky and fragile - but it needs 
cryptsetup and dm-verity anyways. 

The recovery remains mounted and available for chroot.

# Boot sequence - USB installer

The BIOS must be set to insecure mode - this should also clear the TPM keys.
Booting from USB signed EFI is the same as regular disk - will use the same labels.

- Boot from a USB drive EFI partition
- Will load an unsigned UKI image, and look for USB_BOOT partition
- After udevd start, wait 6 seconds for a key (vs 2 for the secure boot)
  - 'a' opens an admin shell before the next steps, give a chance to inspect the system
  - 'c' will run enable asking for the LUKS password if TPM2 is not found or fails.
  - 'r' will boot into the recovery image
  - 's' will start /bin/sh in the rootfs
- rest of the process is the same
- the EFI partition may include authorized_keys, wpa_supplicant, interfaces to auto-conf

Once recovery is booted, SSH into the machine and run the install scripts (or use it as is)

# Boot sequence - VM

Using cloud_hypervisor for now, virtiofs works better than in qemu. Eventually want to use crosvm,
also test firecracker and others.

For fast startup - not using EFI, but 'kernel' and 'initrd'. The initrd is required with the stock
kernel since critical modules are missing. 

The initrd is more minimal, and is driven by the kernel cmdline:

- mount /dev/vdb as squashfs+overlay - /lib/modules/$(uname)
- mount /dev/vda as /initos/recovery - squashfs+overlay
- if 'initos.vr' is set - mount virtiofs /dev/root as /sysroot
- else: mount /dev/vdc as /sysroot, and mount virtiofs as /x

# Rootfs (full)

A 'full' rootfs includes an init - openrc, sysv or systemd (not recommended but works).
`setup-deb install-init` should add the required packages.

# Rootfs (OCI/container)

The goal is to use plain OCI images as rootfs - without init or 'host' packages. To support this, 
the recovery disk will be run first and will handle init and hardware.

