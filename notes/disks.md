# Disk organization notes

## Servers 

- 2+ NVME
- btrfs on both for /x
- 1 EFI on each 
- may have LVM too (optional) - /x can be on LVM.

## Mobile

- single disk - can be as little as 16G (or less)
- 2 1G EFI partitions (1 and 2). Can be 512M each.
- rest is LUKS btrfs

# Volumes

- home - about 32G (12G is current)
    - .cache, containers, go on separate partition or ignored (not backed up)
- 