# Sidecar OS


## Generating the signed EFI 

We start with a signed EFI - including kernel, cmdline and essential modules with a set of scripts using busybox/alpine, just enough to load the verity image. The image hash is included in the initrd inside the signed EFI, along with the hash of the 'modloop' containing the modules
and firmware.

The verity image contains the 'sidecar OS' - which handles unlocking the disks (TMP/2 or user input), upgrades, networking and either switching to the 'main' OS or running the 'main' OS along with other VMs and containers.

The main OS - just like any VM or container - doesn't handle kernel modules, disk initialization or networking - even if we give control to
a systemd-based OS, the sidecar will still run as a priviledged container 
or chroot along with the main OS.

A small debian or Nix - without systemd - works very well.

## Which kernel ?

Currently using debian kernel/firmware/modules - with the mkinitrd and busybox from Alpine which runs as sidecar and initrd.

Nix and Arch linux kernels should work too.

Alpine and OpenWRT kernel don't work very well with Debian and don't support Nvidia so far.

## Sidecar content

The script to generate sidecar currently creates a 'fat' sidecar - including the 'builder' (mkinitrd, efi tools), init utils (tmp, luks, filesystem), networking. 

I am also adding wayland and X11, python and node, as well as Nix- in many cases the sidecar can be used fully standalone without a 'main' OS.

The script can be easily changed to only include the minimum - but for now 
I'm trying to push the limits and see how much I can do with Alpine+Nix combo, using Musl packages from alpine when available and Nix for the rest,  and the 'debian' main OS relegated to VMs.

## Sidecar and VMs

The startup script for VMs can (and should) mount the sidecar and the /nix store (read only or overlay). Normally the initrd script for VMs can take care of network setup and mounts.