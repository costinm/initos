- create a 2G EFI partition (making space somehow)
- label BOOTB
- copy the files from an Initos /boot/efi or build

- create a LUKS partition, with btrfs and initos/ dir.
Add 2 keys - one random and one recovery (login)

- if the machine has tpm2:  save the random key to TPM2, 
copy the handle to efi partition as initos/tpm_handle
`tpm2_getcap handles-persistent` to check.