# Boot sequence

After install and provisioning the signing keys:

1. EFI loades the initos signed Kernel+initramfs UKI file according to the 'next boot' or default.
2. The image signature is verified by firmware.
3. The initramfs mounts the partition containing the signed Initos image
4. Using the signature included in the signed kernel, use verify to 
enable verification on the image, mount it RO + an overlayfs
5. Copy the /local dir containing signed configs (CA root, etc)
6. Pass control to the Initos image.

The InitOS image is an alpine image with a custom init script responsible for machine initialization:
- load kernel modules, start udev, initialize hardware
- unlock the TPM2 and get the LUKS key, or ask the user for the key
- use the key to mount the LUKS partition

Based on the (signed in the UKI or encrypted in LUKS) configuration, 
it may:
- switch root to one of the 'rootfs' subvolumes on the encrypted disk 
- start one or more pods and VMs using rootfs and images on the disk
- if the rootfs is not using systemd, both.

InitOS will continue to run as a sidecar - mainly the SSHD and 
udev handling.

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

