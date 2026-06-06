# Kernel Build Session Summary

## Context

The kernel build is driven by the nix flake or `scripts/setup_kernel.sh` in the current build environment. Kernel base configs and fragments live under
`linux/`.

## Environment

- For debian hosts, sidecar/bin/setup-deb contains functions to install packages, need to be run with sudo - or a container created. 
- if nix is installed - use the flake.

## Current Defaults

- `scripts/setup-kernel` defaults `BRANCH=6.18`.
- Base config inputs are:
  - `linux/6.18/config.amd64`
  - `linux/6.18/config`
- Host fragments merged by `kernel_cfg` include:
  - `builtins.fragment`
  - `filesystems.fragment`
  - `block.fragment`
  - `crypto.fragment`
  - `usb.fragment`
  - `containers.fragment`
  - `net.fragment`
  - `networking.fragment`
  - `mods2.fragment`
  - `efi.fragment`
  - `host-lenovo.fragment`
  - `cros/hatch.fragment`
  - `host-chromeos.fragment`
  - `tpm2.fragment`
  - `display.fragment`
  - `y-remove.fragment`

## Resume Commands

Expected outputs after `kernel_pack`:

- `target/img/bzImage`
- `target/img/.config`
- `target/img/modules-$(cat /build/linux/include/config/kernel.release).erofs`

