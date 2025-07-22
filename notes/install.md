# Fresh install

- boot from USB
- run `setup-secure wipe /dev/DISK` to create GPT partition on the disk
- run `setup-secure initTPM`

# Upgrade existing linux

- create or make sure a 2G EFI partition exists (making space somehow). Label as BOOTA. If possible, make a second one, with BOOTB label.

- find a btrfs partition with enough space - set the label to BTRFS_BOOT, copy the files to ./initos

- attach the USB disk, make a backup 

- make space for the LUKS partition


- copy the files from an Initos /boot/efi or build

- create a LUKS partition, with btrfs and initos/ dir.
Add 2 keys - one random and one recovery (login)

- if the machine has tpm2:  save the random key to TPM2, 
copy the handle to efi partition as initos/tpm_handle
`tpm2_getcap handles-persistent` to check.