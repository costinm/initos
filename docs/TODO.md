# TODO and ideas

## Firmwared 

Debian uses ZX, Alpine ZSTD - to have the firmware independent of distribution we effectively need to 
uncompress (which is fine since we put it in a sqfs). A different approach is to use a service that
may also download firmware from a control plane, and only keep network and disk on the boot.