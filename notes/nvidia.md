# NVidia handling

## What didn't work well

Docker/podman running in alpine (sidecar) and handling the GPU is 
a pain and even on debian it's a bit scarry if running on the raw host.


Passing the PCI while using virtiofs-mounted moudles - hangs. 
Works fine otherwise.

Building and managing the virt kernel in the rootfs: hard to update.

Alternative: separate OCI image for the kernel/modules/nvidia for 
virt, exported to a btrfs or sqfs file. Doesn't need signatures.