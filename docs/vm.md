# VMs

There are countless solutions for running VM, from qemu to large scale cloud
providers. Most of them focus on the 'cloud' use case and on running a full 
OS - all the way to booting with emulated EFI, boot loader, and 'cloud init'
as a way to further customize the machine. There are solutions to run container
images in a VM - typically by running a full OS and podman/docker inside, 
with the VM shared by multiple containers.

InitOS approach is closer to 'serverless' - it can run an OCI 'rootfs' directly
under the VM, with InitOS handling init to what is typical for a container - 
networking, mounting volumes - and having the 'real' OS only deal with its 
services.  The machine initialization, remote control and kernel upgrades are handled by InitOS - but it is not intended as a full OS, just a specialized sidecar, with OCI images used as 'real OS'. 

## Decisions

- using VirtioFS provides a good way to share volumes with the host and other containers. SSHFS, 9P also work in a similar way, having a host dir where bind
mounts can be used.

- Each machine uses a bridge where VMs and containers are added - it can't use
CNI (since VMs are not containers), but very similar in concept. An udev rule
adds the VM host pair to the bridge. Expectation is that some mesh policies
will be applied and mesh will handle cross machine networking for complex
users with multiple tenants - while simple/small cases can stay very simple.

- No attempt to scale or handle complex cases - use a cloud provider for that,
the goal is to have a simple/secure solution for home and small clusters. Each
machine gets a /24 range, routes or bridge can be used directly (no iptables magic), scripts for setup.

The 'control plane' will handle the EFI signing and upgrade of the machines - it
will also handles the IP allocation for VMs/pods and registering them to DNS.


## InitOS VM support

InitOS goal is to secure the machine startup by using signed EFI and
passing control to a different operating system, after unlocking the 
disk. It includes common tools to manage the machine - as well as a SSH
server for recovery, upgrade and control.

The user OS can be executed using `switch-root` - and doesn't need to handle
the initial OS startup, can be just like a Pod or container.

It is possible to run it in a real container instead of switch-root, leaving
InitOS run as a 'sidecar'.

It can also be run in a full VM - a bit more expensive but more secure too.

The InitOS image includes cloud-hypervisor in /opt/virt.
Crosvm would have been a better choice - but there is no
precompiled binary that I found, and firecracker seems to have too few features, while qemu is too large and seems to have more bugs with virtiofs, 
but either would work.

## Initializing the VM

Typical VM includes EFI partition, Grub, kernel, modules and systemd. Upgrading the kernel is similar to a host. 

With InitOS the goal is to modularize the initialization - and 
treat the OS as a container, without 'concerns' about init.

Unlike a host, the VM has a smaller list of hardware - but can still get assigned PCI devices so Nvidia and other modules are 
needed. 

## Command line

For USB installer, host config is stored under /initos/etc subdir. 
For hosts, it is under /x/initos/etc.

For early VM init - we don't have disk, so using few kernel command line options:

- Everything after "-- " is treated as the app to run after pivot.
- xip=IP used to init the IP.

# Boot sequence - VM

Using cloud_hypervisor for now, virtiofs works better than in qemu. Eventually want to use crosvm,
also test firecracker and others.

For fast startup - not using EFI, but 'kernel' and 'initrd'. The initrd is required with the stock
kernel since critical modules are missing, and to avoid DHCP or guest-dependent networking.

The initrd is more minimal, and is driven by the kernel cmdline:

- mount /dev/vda as / (btrfs)
- mount virtiofs as /z (shared disk)
- pass control to the OS

The VM may run an init system ( including but not recommended systemd, if you want to use Gnome or 
other software that depends on systemd ), or it can run a single program, like a Pod.

# VM installation

The VM image is created from a OCI image, using mkfs.btrfs ability to include an initial set of files.
No root required, no significant differences from 'container' setup and VM setup - just stronger isolation.