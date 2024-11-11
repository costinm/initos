# TODO and ideas

[ ] Before releasing - remove the debug shell in secure mode.
    Only 'usb' should have shell on console.

## Firmwared 

Debian uses ZX, Alpine ZSTD - to have the firmware independent of distribution we effectively need to 
uncompress (which is fine since we put it in a sqfs). A different approach is to use a service that
may also download firmware from a control plane, and only keep network and disk on the boot.

## USB recovery

[x] For both secure and insecure mode, it is useful to have a dedicated key to trigger looking for the USB_ label for recovery. The problem in secure mode
is finding the signatures - currently they are locked in the signed initrd in the /boot partition.

[ ] keep the root.pem in the /boot, and sign the verity signatures.

