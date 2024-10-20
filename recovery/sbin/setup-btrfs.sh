#!/bin/sh

check() {

}

seed() {
  # Disk is read only - but allows adding a new disk, where the writes will go.
  # This can be useful with VMs, sharing a RO base.
  btrfstune -S 1 ${dev}
}

# Check all files and meeta checksums. Reports go to /var/lib/btrfs.
# Docs recommend monthly, from cron. Will use 80% of bw.
scrub() {
  btrfs scrub start -B /x
  btrfs filesystem defrag -v -r -f -t 32M /x
  duperemove -dhr /x
  btrfs balance start -m /x
}

ext4() {
  local disk=$1

  e2fsck -fvy ${disk}
  btrfs-convert ${disk}

  # btrfs subvolume delete /x/ext2_saved
}
