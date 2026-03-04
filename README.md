# Simpler verified OS initialization

The goal is to simplify verified boot for common  physical machines, replacing the usual Initrd (dracut, etc) with a minimal and easier to understand and review boot process.

Choices:
- Only EFI 
- kernel compiled with NVME, Sata, MMC, USB and ext4/erofs in the kernel, not as modules.
- a single rust app in the initrd.
- Limine as bootloader - with kernel/initrd/cmdline SHA and the 'root' public key loaded into config and signed. 
- One 'ext4' data partition, with STATE partition label is loaded - with fsverity and fsencrypt enabled. Inside the 
img/ROOT-A.img and other images are signed with the public key from kernel command line.

The main idea is that the boot partition only changes if the
kernel or initrd is updated - while rootfs and any other image can be updated independently and signed with the key
included in the verified boot config.

For unverified boot - no need to use initrd, can directly boot
to rootfs.

Rationale:
- options add complexity and risk. I used this for my own machines and I don't want to deal with complexity at home.
- Clear separation of 'signed EFI path' and rootfs -  starting from EFI signing key verifying the EFI binary including the SHA of the config, config including SHA of kernel/initrd and the public key for rootfs signing.
- Minimum possible initrd - only verifies rootfs image with fsverity, using the public key from the signed config file.
- Limine still has too many features, but simple enough to not be worth replacing for now. 
- We need a writable disk anyway - btrfs can be loaded later, ext4 has fsverity/fscrypt and good enough for a rootfs, images and any normal files.
- Avoiding partitions and complex block magic - just 2 partitions required. 
- using fsverity/fscrpt is useful post boot for a lot of other use cases, more dynamic. Upgrades involve just copying files.
- the model works well with central build system - where all 
signing happens. All other machines just get signed images and
 signed configs.
- UKI EFI has no clear benefits - looked pretty closely and complexity is not worth it.

After switch-root, the rootfs init script will use the pubkey to verify configs and mount other volumes - including for enabling TPM and loading fscrypt directories using TPM or 
password or via remote access, using public key as authorized SSH CA. 

At the end of the boot sequence control is passed to the user rootfs, which can be any linux variant, including images extracted from container images. Or the signed configs in 
volumes are used to start VMs and containers, with no other rootfs.

## Partitions

- 1 or 2 32M partitions for the A/B EFI - P12 EFI-SYSTEM
- 1 or 2 4G recovery/default disk - read/write ext4, can be ROOT-A/ROOT-B from chromebooks.
- about 100G for the ext4 rootfs - STATE, or more. Will hold crypted home and images.
- some space for BTRFS or LVM if needed, in particular for servers or dev machines. For VMs - BTRFS images are simpler.

On multi disk systems - EFI and recovery on each disk.

# Background

The main reason for writing this is that I got too frustrated with having to deal with Grub and Dracut and the general model of Linux booting - where each machine has to create its own init image that only work on that machine. Security is so complicated and likely to fail that few bother - and the fundamental design of having each host deal with signing and 
building the boot image is IMO fundamentally flawed. 

