# Fork for Alpine mkinitrd

Alpine mkinitrd is one of the cleanest - but has a few alpine-specific features and the same 'opaque' design as the others.

Instead:
- break appart each operation, building the filesystem step by step
- each operation is a separate call - very much like a step in dockerfiles.

## Tools

Commands:

- initfs_base - create core directories and copies over files
and their dependencies (detected with lddtree)
- initfs_kmods - copy modules and their deps.
- initfs_firmware - for each module in the destination dir, copy the required firmware. This tool also works for a rootfs.
- initfs_cpio - create a initrd cpio based on the current dir.
