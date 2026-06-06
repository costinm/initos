# InitOS design

Goals:
- verified boot: protection against 'evil maids' and lost device. 
- very minimal and simple code that can be reviewed and changed by regular people or LLMs.
- focused only on the boot - EFI, kernel, main disk, rootfs loading.
- includes TPM or key unlocking of a system dir
- verify an initial rootfs or use the encyrpted system dir for rootfs.
- independent of the OS or distribution
- the boot signing should be done on a secure machine - no signing
or changes possible on the hosts.

## Secure boot

Secure boot is required for verification - including removing all other keys and installing the keys used by the build/signing machine.

If a machine doesn't have secure boot enabled - it can still be used, but shouldn't be trusted, i.e. no private files or use with the 'main' account.

## EFI

- Minimal Rust EFI that just verifies kernel/initrd/cmdline
- alternatively Limine or even Grup can be used

The custom EFI is using the same DB-keys that sign the EFI binary to
verify the kernel, cmdline and initrd.

## Kernel

A custom kernel is used - because most distros don't include the 
required drivers to load NVME/SATA and EXT4/EROFS/FSVERITY. If a distro does - the kernel can be used. Android CF kernels are close,
but don't have all modules.

Modules and firmware are packed in erofs, with fs-verity and signing.

## Initrd

One rust binary:
- find LABEL=STATE disk, mount it as /z
- if TPM is used - get the key, else ask for the fs-crypt pass
- unlock the /z/c disk as fs-crypt
- verify img/initos.erofs and mount it as root
- switch to the root.

## InitOS image

Included features:
- busybox
- few scripts to locate the real root and pivot.
- will mount firmware/modules too

## Rootfs

Can be a dir under /z/c (fs-crypt) or a signed fs-verity erofs - so it can't be modified by evil maids. For erofs - an overlay is used,
with the upper layer under fs-crypt.

I normally use Debian, I tried Arch - now looking for NixOS and/or
Nix with a small debian skeleton.

