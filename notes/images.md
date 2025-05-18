# InitOS OCI images

A range of options - from many small specialized images to few larger ones. There are tradeoffs - and both small and large images can be generated.

For the initial stages I'm using a middle ground:
- 'sidecar' - 'all included' Alpine image ('sidecar'). It could be split into:
    - 'builder' - tools to build/sign the EFI UKI
    - 'sidecar' - common tools for management (post boot) or as minimal root
    - 'boot' - minimal tools used during boot (LUKS, podman)
-'kernel' image with Debian kernel, firmware and nothing else
    - currently has a bunch of utils - but plan to remove them. They don't add a lot in size and help debug.


Once the disk is unlocked and network set, control is passed to 
either VMs/containers or switched to a different rootfs. The 
rootfs does not include kernel or low-level utils - any OCI image
can be converted to a rootfs.

For servers with Nvidia cards:

-'gpu' + Nvidia drivers - for specific machines
    - this is very large, Nvidia has many deps including systemd
    - as such - included both cloud and normal kernels, but may keep only hardware, passing the PCIx to a VM seems a bit tricky.

For everything else:

- 'codeui' - no kernel, usable as container or VM
    - includes KasmVNC and LabWC - can be used as real root
    - includes systemd, podman, Code and Chrome

Any OCI image should be able to start in container, VM or as a switch_root.
