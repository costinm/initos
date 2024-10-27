# Musl and Glibc kernel module loading incompatibilities

Using an Alpine kernel with a Debian rootfs appears to break module loading, when
debian compiled modprobe is used. That means Debian rootfs won't work with the Alpine kernel unless Alpine is handling the hardware.

Few choices:

1. Use a glibc-compatible kernel - like debian. Alpine has no issues with it. 
2. Always load recovery as a sidecar, and use it for system management (mods, network).
3. Load recovery as main rootfs, debian as a container or VM

The main reason for running debian root is to get access to NVidia drivers - which are 
not available in Alpine. It seems reasonable to do all of the above - use debian kernel,
have recovery availabe as a (privileged) container - and either run debian as rootfs directly or as a container. 

Any development, K8S nodes, etc. should be in VMs anyway, for security. 

