# Sidecar OS

We start with a signed EFI - including kernel, cmdline and essential modules 
with a set of scripts using busybox/alpine, just enough to load a signed image.

The signed image contains the 'sidecar OS' - which handles unlocking the disks (TMP/2 or user input), upgrades, networking and launching the 'main' OS.

The main OS doesn't handle kernel or initialization - can be anything that can run in a container, and may be run 'raw' or in a container or VM - and 
multiple 'main' OSes can be started as well.

Question is: what OS to run as sidecar. 

Alpine is great - small size, simple startup. But it lacks Nvidia support, 
so will need a separate debian for that. 

A small debian - without systemd (which may be used for the 'main' OS) - also works, and it reduces the complexity a bit (no need to use Alpine except as a builder and base for the initrd, and for small containers)

For an Nividia-based server: Debian seems the best choice.

For an old laptop used as a (more secure) UI: Alpine seems good enough.
Original idea was to use the debian kernel with Alpine rootfs as a container - but if we don't have to deal with NVidia, can just use alpine kernel.