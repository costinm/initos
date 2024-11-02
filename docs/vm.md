# VM support

The recovery image includes cloud-hypervisor - mostly because it is lighter than qemu and seems to work better with virtiofs. Crosvm
would have been a better choice - but there is no precompiled binary that I found, and firecracker seems to have too few features.

In addition recovery can run in cloud-hypervisor ( and probably most other VMMs).

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