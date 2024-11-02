# Fresh install

- boot from USB
- run `setup-secure wipe /dev/DISK` to create GPT partition on the disk
- run `setup-secure initTPM`

# Upgrade existing linux

- make sure the EFI partition has ~xxx space
- find a btrfs partition with enough space - set the label to BTRFS_BOOT, copy the files
- attach the USB disk, make a backup 
- make space for the LUKS partition
- 