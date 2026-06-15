# InitOS design

Goals:

1. Minimal "secure boot" that can be reviewed and changed by regular people (or LLMs), without feature complexity. A pair of 
Rust programs (the EFI bootstrap and the initrd binary) plus Linux kernel.

2. TPM or key unlocking for a fs-crypt 'system dir', fs-verity
verification for modules/firmware and other erofs images.

3. independent of the OS or distribution - once the rootfs is verified and system disk is unlocked - InitOS is out of the picture. 

4. Safe, controlled upgrade: the boot signing is done on a separate secure machine - no signing or changes possible on the hosts - and
deployed using A/B boot partitions.

## Secure boot

Without secure boot - with only your own keys, without Microsoft
or platform keys - there is no protection against 'evil maid', i.e.
people with access to the machine who can boot a different OS
and intercept the boot.

If a machine doesn't have secure boot enabled - don't throw it
away, but it shouldn't be trusted, i.e. no private files or use with your online account. It is ok as a target for an encrypted
backup or similar - keeping in mind that majority of Linux distros
didn't encrypt or secure until recently (and many still don't).

The produced boot partitions include the PK / KEK / DB keys that
need to be added - after removing the platform ones, because
otherwise any distro using the existing keys could be booted.

## Kernel

A custom kernel build is used - because most distros don't include the required drivers to load NVME/SATA and EXT4/EROFS/FSVERITY. If a distro does this - its kernel can be used, but I think any 
user concerned with boot security should be able to customize
and build a kernel along with the minimal boot components included.

The kernel build is using nix (a debian script is also included)
with fragments to enable the essential drivers. I'm also including
common hardware I have on my laptops.

## Initrd

One rust binary - behavior described in boot_sequence.md - dealing
with the core disk initialization and fs-crypt/fs-verity setup.

It currently includes busybox and few scripts for 'dev/recovery',
not used if secure boot is active.

## Rootfs

The actual Linux rootfs can be in a dir under the fs-crypt disk 
or as a (signed) erofs image.

Multiple rootfs can be present and selected for versioned upgrade. 

I normally use a Debian base plus Nix package manager.

I tested with Arch as well - now looking at NixOS and using
regular docker containers as roots.

## Testing

Integration testing with qemu, softtpm - driven by scripts.

## LLM usage

Almost all current code is LLM generated - original code was 
a set of scripts and Golang code that was converted all to Rust.

When I started the project I had a far more complicated setup - 
still simpler than Grub/Dracut - and very little time to deal with it, and I was curious if different LLMs can make small fixes or 
features - I used local LLMs for most of the code, but recently 
switched to larger models for deeper reviews (and convenience).

Compiling Linux and dealing with EFI and signing is complicated - it took me a long time and I have a bit of experience in this, the
point of using LLM is to make sure other people can fork this
project and make their own changes using LLMs with some reasonable
confidence.