# initos — Simpler Verified OS Boot and Initialization

`initos` is focused on the owner-signed host initialization and early boot.

"Owner Verified" boot means the kernel, modules and initial rootfs are signed by keys owned or trusted
by the machine or mesh owner - and the EFI is locked to only allow those keys, instead of keys
from other vendors. Currently the EFI 'db' key is used to check all components in the early boot
sequence - including kernel modules and the read only rootfs, and should be setup with only the 
owner keys.

By integrating **UEFI Secure Boot**, **fs-verity**, and **TPM2 policies**, it decouples the bootloader
and kernel verification and TPM unlock from the host OS, providing a container-like read-only environment
to run any Linux distribution - with the job of handling Grub/kernel/modules separate from the 
main rootfs (as it would be in a container). 

The goal is to simplify verified boot for common  physical machines, replacing the usual Initrd (dracut, etc) 
with a _minimal_ and easier to understand and review boot process. Minimal is the key, keeping only features
that can't be removed - to make it easier to underastand what is actually happening and how the trust model
is enforced.

On most Linux distros the EFI uses Microsoft keys and a stub that signs a broad set of kernels, with
modules signed by the distribution owner along with the kernel. When 'MOK' (machine owner key) is 
supported for user-built kernels, the user keys are used in addition to all the existing vendor and
platform keys, with a very complicated dance.

The current init is using TPM2 to unlock a 'system' dir using fs-crypt - instead of the more common
and less flexible LUKS. This allows the owner to have additional dirs with different fs-crypt 
keys, unlocked later - as well as un-encrypted but fs-verity checked images in different dirs.

---

## Architecture Overview

The boot chain establishes a secure path from the UEFI firmware up to the execution of the target operating system:

```
┌──────────────────────────────────────────┐
│        EFI Loader (src/bin/efi.rs)       │
│  · Reads /EFI/BOOT/config                │
│  · Verifies config signature using db    │
│  · Loads/Verifies kernel using db cert   │
│  · Handover to Linux kernel              │
└────────────────────┬─────────────────────┘
                     │
┌────────────────────▼─────────────────────┐
│       initos / initos-init (PID 1)       │
│  ┌─────────────────────────────────────┐ │
│  │ mount.rs                            │ │
│  │ · mount_pseudo_fs (proc/sys/dev)    │ │
│  │ · find_partition_by_label (STATE)   │ │
│  │ · mount_ext4 / mount_loop           │ │
│  │ · switch_root                       │ │
│  └─────────────────────────────────────┘ │
│  ┌─────────────────────────────────────┐ │
│  │ verity.rs                           │ │
│  │ · measure_verity (ioctl)           │ │
│  │ · digest_to_hex                     │ │
│  └─────────────────────────────────────┘ │
│  ┌─────────────────────────────────────┐ │
│  │ verify.rs                           │ │
│  │ · verify_signature (Ed25519)        │ │
│  │ · verify_image                      │ │
│  └─────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

In progress: the minimal EFI loader stub can be removed to further simplify, booting directly to a kernel 
with the initos initrd and cmdline 'built in' and locked. 

Initrd is using partition or disk label - and signatures on the binaries - to load the rest.

---

## Core Benefits

- **Zero-Trust Boot Chain**: Validates everything from the UEFI Secure Boot DB keys all the way up to the filesystem blocks using fs-verity Merkle trees.
- **Host Portability**: Replaces machine-specific ramdisks. The same static `initos` initrd binary works across all physical servers
- **Frictionless Upgrades**: Upgrading the kernel is as simple as copying few `.erofs` images and its accompanying `.sig` signature to the STATE partition, along with writing one of the 64M A/B boot partitions. The rootfs is also either an image or a directory. 
- **Encryption**: Out-of-the-box support for TPM2 sealing (locked to PCR 7 policies with automatic anti-replay extension lockout) or boot key, using fscrypt-based folder encryption.
- **Auditable & Small**: Written in Rust with minimal dependencies, replacing thousands of lines of shell scripting in standard initramfs generators.

---

## Boot Sequence Details

1. **Firmware Stage**: The UEFI firmware executes `initos.EFI` (built from `src/bin/efi.rs`). The loader reads the kernel command line from `\EFI\BOOT\config` and verifies its signature (`config.sig`) against the Secure Boot `db` certificate. It then verifies and executes the kernel (`bzImage` and `initrd.img`).
2. **Mounting Pseudo Filesystems**: Upon initrd start, `initos` is executed as PID 1. It mounts `/proc`, `/sys`, and `/dev`.
3. **Partition Discovery**: `initos` scans block devices in sysfs for a partition or EXT4 volume labeled `STATE` and mounts it as /z.
4. **fs-verity Verification**: Once mounted, it measures the EROFS system image (`img/initos.erofs`) and validates its cryptographic hash against the signature file (`initos.erofs.sig`) using a public key passed via kernel command line `INITOS_PUB_KEY`.
5. **Switch Root**: The image is loop-mounted, the `STATE` partition is bind-mounted at `/z` inside the new rootfs, and `initos` performs a `switch_root` to run the OS init (defaults `/opt/initos/bin/initos-init-ver` - `INITOS_INIT` command line override).

---

## Partition Layout

A standard installation expects the following drive partitions:

| Partition Name | Typical Size | Filesystem | Purpose |
|----------------|--------------|------------|---------|
| `BOOTA`        | 32 MB        | VFAT       | Active UEFI Boot (Kernel, Loader, Configs) |
| `BOOTB`        | 32 MB        | VFAT       | Alternate UEFI Boot (A/B updates) |
| `STATE`        | 16+ GB      | EXT4       | Contains read-only system images and encrypted user data |

### Layout on `STATE` Partition:

- `/img/` — Read-only EROFS images (e.g., `initos.erofs`, kernel modules, firmware)
- `/c/` — `fscrypt`-encrypted directory for home directories, mutable settings, and distro overlays.
- `/c/roots/ROOTA` or `/img/initos.erofs` - the default rootfs, configurable.

---

## Developer Tooling & Verification

`initos` binary also provides tools to manage images, encryption, and TPMs.

### Subcommands

Run `initos help` to list all subcommands:
- `initos verify <IMG>`: Verify an image against its signature using `INITOS_PUB_KEY`.
- `initos mount <IMG> <DIR>`: Cryptographically verify and loop-mount an EROFS image.
- `initos primary`: Create an RSA-2048 primary storage key in the TPM owner hierarchy.
- `initos seal <SECRET>`: Seal a key to the TPM under PCR SHA256:7.
- `initos unseal`: Unseal the TPM secret to stdout.
- `initos lock_tpm`: Extend PCR 7 with random data to prevent further unsealing during this boot.
- `initos fscrypt-setup <DIR>`: Setup v2 encryption policy on a directory.
- `initos encrypt` / `decrypt`: Multi-recipient age/X25519-compatible encryption.

---

## Build and Container Cycle

The build is based on 2 nix flakes - top level 'initos' for the rust and utils and 'linux'
for the kernel compilation with the required options. Technically other kernels that have
the essential drivers built in can be used as well. 

## Background

The main reason for writing this is that I got too frustrated with having to deal with Grub and Dracut and the general model of Linux booting - where each machine has to create its own init image that only work on that machine. Security is so complicated and likely to fail that few bother - and the fundamental design of having each host deal with signing and building the boot image is IMO fundamentally flawed. 


## Notes/rationale

- The EFI DB is critical to verify the EFI - zero trust in distributions, so my own key sigining EFI. I can also use the same key to sign kernel, cmdline and the images. Custom EFI loader is used instead of Limine for better secure boot integration and minimal features - the EFI doesn't need to be recompiled or patched with keys. UKI EFI has no clear benefits - looked pretty closely and complexity is not worth it.

- minimum and optional initrd - only verifies rootfs image with fsverity, using the public key from the signed config file. 
This also works as a separate dm-verity partition - but a bit more complicated. Scripts create this as well.

- We need a writable disk anyway - ext4 has fsverity/fscrypt and good enough for a STATE partition holding signed images, signed configs and encrypted home and configs. Additional btrfs/LVM/etc disks can be used as needed.

- Small A/B partitions for EFI. The EXT4 parititon hold versioned images, modules and everything else.

- using fsverity/fscrpt is useful post boot for a lot of other use cases, more dynamic. Upgrades involve just copying files.

- the model works well with central build system - where all signing happens. All other machines just get signed images and signed configs.

Spent a lot of time to get TPM/2 work - but I think it is only useful for unattended server reboot. For laptops - entering a password after boot is not a huge effort.

## EFI loader

1. Limine is a relatively minimal boot loader that works well. The config, initrd can 
be signed along with the bootloader, it works pretty well.

2. Using a linux kernel with initrd and command line built in (compling the kernel after 
the initrd is generated) is also possible and avoids an extra step. It assumes kernel
doesn't accept additional command line options.

3. I wrote (with LLM help) a very minimal loader, using the DB key (same key used to sign
the EFI) to also sign kernel/config - to simplify the steps and allow them to be updated
independently of the EFI (not the case with limine). Works well - except on one old
laptop.

Either one seems to work fine and make different tradeoffs.

The boot partitions only holds the kernel, bootloader and configs (in option 2 - only
the kernel as EFI/BOOT/BOOTX64.EFI).

Assuming 2 ESP boot partitions (BOOTA and BOOTB) this can be updated safely by replacing
the entire parition with a new image.
