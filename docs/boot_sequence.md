# Disk layout 

- EFI partition with label BOOT, containing:
  - the signed UKI kernel image
  - additional UKI kernel image versions.
  - firmware.sqfs 
  - modules-VERSION.sqfs for each version
  - recovery.sqfs
  - verity images for each sqfs. The initramfs contains the hash of each verity image.
- LUKS partition containing a BTRFS filesystem
  - one or more rootfs subvolumes
  - @home, @log, @cache subvolumes
  - swap
- LVM partition for the use with VMs.
- A USB disk with the same layout and label USB_BOOT can be used for recovery if the 
main EFI is corrupted.

# Default boot sequence (secure, TPM2)

1. EFI loads the signed UKI image
2. kernel inits and load the bundled initramfs
3. the custom /init script starts as user 1
4. the script checks it is running as user 1, start the init sequence
5. init basic filesystem and mount /proc, /sys, etc (initramfs_1st, mount_proc)
6. load the simpledrm module (to show info on the display)
7. load additional modules common for finding the disk (initramfs_mods)
8. start udevd, wait for it to settle
9. locate BOOT partition (should be the label on the EFI partition)
   - if USB_BOOT is found - it will be used instead
10. mount recovery, modules and firmaware sqfs - using dm-verifty with hash from 
  the signed initramfs
11. chroot into recovery to run TPM commands to unlock the LUKS partition
12. once the LUKS is unlocked, mount the rootfs and switch to it - using a config file 
  under /initos/ subvolume.

Including tpm2 and all related modules on initramfs is tricky and fragile - I got it working eventually but decided it's too much trouble and complexity on initramfs.

The recovery remains mounted and available for chroot.

# Boot sequence - installer / recovery

The BIOS must be set to insecure mode - this should clear the TPM keys.

- Boot from a USB drive, with the USB_BOOT EFI partition
- Will load an unsigned UKI image 
- After udevd start, wait 6 seconds for a key
  - 'a' opens an admin shell before the next steps, give a chance to inspect the system
  - 'c' will run enable asking for the LUKS password if TPM2 is not found or fails.
  - 'r' will boot into the recovery image
  - 's' will start /bin/sh in the rootfs
- rest of the process is the same
- the EFI partition may include authorized_keys, wpa_supplicant, interfaces to auto-conf

Once recovery is booted, SSH into the machine and run the install scripts (or use it as is)

# Boot sequence - VM

If a /dev/vda disk is found - will skip loading LUKS or TPM. Instead, load the modules 
and recovery from /dev/vda, /dev/vdb, etc.

This is currenly mostly for testing and recovering images with bad passwords or content.
