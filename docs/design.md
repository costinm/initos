# InitOS design

Goals:

1. Minimal, distribution-neutral "secure boot" that can be reviewed and changed by regular people (or LLMs), without un-necesary complexity. 

2. Opinionated encryption and verification: fs-crypt with TPM or key unlocking and fs-verity with composefs.

3. Independent of the OS or distribution - once the rootfs is verified and system disk is unlocked - InitOS is out of the picture. Tested with Debian and NixOS. 

4. Safe, controlled upgrade: the signing is done on a separate secure machine or in Github actions - no signing or changes possible on the hosts. Upgrades are using A/B EFI boot partitions and OS images.

This is implemented as:
- a pair of Rust programs (custom EFI bootstrap and the initrd binary)
- Linux kernel with custom config
- one patch to simplify the key config (using the builder signing key for all components).

One option (which may become the default) is not using a custom boot loader at all, but instead
signing the Linux kernel, which can boot directly - but with locked down command line and a built-in
initrd containing the initos rust file.

## Secure boot

Most modern machines support verification of the initial boot sequence, using keys installed in the 'BIOS' firmware setup. 

The default is unfortunately wide open: pre-installed keys allow not only firmware vendor, but 
also Microsoft, Grub and few other 'boot loaders' that in turn can boot and run almost anything.

The first thing to do is remove all verification keys (PK, KEK, DB) - most firmwares allow this,
and install only the keys used by your build machine. That locks the computer - it can be unlocked
by someone with physical access that runs the firmware again, but the TPM keys will be reset,
so the encrypted disks can't be accessed.

The boot is opinionated, with very few configurations - but this keeps code simpler and all
opinions can be adjusted with code changes. I made changes with multiple LLMs using simple
prompts - and I am not an expert in EFI or kernel - I expect most users who have different
opinions to be able to fork and adjust what they need. I don't like arbitrary config 
complexity, it is easier to operate if things are well defined.

InitOS main artifact is an VFAT image that can be written to a 64MB EFI boot partition.
The scripts use partition 101 and 102 to be out of the way. The image includes the keys
that need to be installed.

It expects partition 1 (or a partition labeled STATE) on the same disk to contain an EXT4 
filesystem, which will be mounted as "/z". After TPM setup, the "c" directory (crypto) will
be unlocked automatically at boot - if TPM (v2) is not setup, it will prompt for a key.

Kernel modules, firmware and optionally rootfs images can be stored in Erofs/composefs files
with fs-verity - and signatures using the same key as the EFI boot loader.

## Kernel

A custom kernel build is used - because most distros don't include the required drivers 
to load NVME/SATA and EXT4/EROFS/FSVERITY. If a distro does this - its kernel can be 
used, but I think any user concerned with boot security should be able to customize 
and build a kernel along with the minimal boot components included.

The kernel build is using nix with fragments to enable the essential drivers. I'm also
including common hardware I have on my laptops - I have few ChromeOS and older machines 
that still work very well as K8S nodes or for my mesh experiments. Maintaining and
building kernels was time consuming - which is the main reason this project was started.

The expectation is that users will fork the repo and add their own custom kernel options 
(and most important: their own signing keys) and let it run. The weekly script pulls
current kernel and rebuilds.

## Initrd

One rust binary - behavior described in boot_sequence.md - dealing with the core disk
initialization and fs-crypt/fs-verity setup. No firmware or modules or systemd or any
other file used  - kernel has the drivers required to open the disk and fs-verity 
compiled in, modules/firmware are loaded from disk.

## Rootfs

The actual Linux rootfs can be in a dir under the fs-crypt disk (mounted as /z/c/roots/ROOTA)
or a (fs-verity + signature) erofs image.

Multiple rootfs can be present and selected for versioned upgrade. 

I normally use/test NixOS and Debian (plus Nix as package manager for Debian).
I tested with Arch as well.

The main adjustment is to disable all systemd units and packages related to boot loading
and kernel - using 'container' images is the simpler way to install the rootfs, since
InitOS attempts to create an environment similar to containers, which get managed disks
and volumes and don't need to deal with kernel/firmware/modules/disks.

## Incremental updates

I don't have a lot of computers - but still pushing large images (firmware in particular)
and binaries is slow. NixOS declarative approach is good - but each machine needs to download
the same files, and maintaining a cache is work.

Building an Erofs image on one machine and distributing it is better - less internet downloads
and work - but still too large and slow.

I have been exploring composefs - both backed by a hash-based object store (composefs-rs, OSTree)
but also backed by raw Nix files.

The idea: create a metadata-only Erofs file, with /nix/store holding the data - same as compose-fs 
but without the file rename. That's both smaller and simpler, nix already has the hashed files.

Assuming Nix is de-duplicated/hashed - the erofs meta will have same deduplication as the object store.

Enabling fs-verity and signing the metadata erofs - like the EFI and modules - makes sure files
can't be modified after boot, which is an improvement over normal Nix.

The missing part is how to sync the files - nix store copy should work for that, with fs-verity 
enabled after the copy for files that don't have it. But another interesting approach is to use the 
metadata-only erofs as a manifest - get it, find missing files, and copy/request the missing files
or packages.

The other approaches - that I tried for firmware files - is to use a git for the binaries (not 
very efficient - composefs-rs is cleaner) or to use a weekly OCI image or erofs containing the
current version combined with periodic 'delta' OCI images. Once the second OCI layer is >20% of
the base image - rebuild the base image. This works with any OCI store including github actions.  

## Testing

Integration testing with qemu, softtpm - driven by scripts.

## LLM usage

Almost all current code is LLM generated - original code was 
a set of scripts and Golang code that was converted all to Rust.

When I started the project I had a far more complicated setup - 
still simpler than Grub/Dracut - and very little time to deal 
with it, and I was curious if different LLMs can make small fixes or 
features - I used local LLMs for most of the code, but recently 
switched to larger models for deeper reviews (and convenience).

Compiling Linux and dealing with EFI and signing is complicated - it
took me a long time and I have a bit of experience in this, the
point of using LLM is to make sure other people can fork this
project and make their own changes using LLMs with some reasonable
confidence.