# Kernel Build Session Summary

## Context

The kernel build is driven by `scripts/build.sh` in the current build
environment. `scripts/container_build.sh` wraps `sidecar/bin/cctl` for creating
or entering build containers. Kernel base configs and fragments live under
`linux/`.

## Environment

- Build container: `initos-kernel-dev`
- Container runtime: `podman` preferred by `sidecar/bin/cctl`
- Kernel source in container: `/build/linux`
- Build artifacts in container: `/build/img`
- Repo path in container: same path as the host checkout, mounted by `cctl`
- Host build cache: `$HOME/.cache/initos-kernel-dev`

## Current Defaults

- `sidecar/bin/setup-kernel` defaults `BRANCH=6.18`.
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
- VM/cloud-specific virtio settings are in `linux/cloud/virtio.fragment`.

## Resume Commands

Create or update the build container and install dependencies:

```bash
bash scripts/container_build.sh kernel_dev
```

Clone/update, configure, build, install modules, and package artifacts:

```bash
bash scripts/container_build.sh kernel
```

Run individual steps inside the container:

```bash
cctl sh initos-kernel-dev /ws/sidecar/bin/setup-kernel get_kernel
cctl sh initos-kernel-dev /ws/sidecar/bin/setup-kernel kernel_cfg
cctl sh initos-kernel-dev /ws/sidecar/bin/setup-kernel kernel_build
cctl sh initos-kernel-dev /ws/sidecar/bin/setup-kernel kernel_pack
```

or equivalent podman:
```bash
podman exec initos-kernel-dev /bin/sh -c "out=/build src=/home/build/ws/initos /home/build/ws/initos/sidecar/bin/setup-kernel kernel"
```

Expected outputs after `kernel_pack`:

- `/build/img/bzImage`
- `/build/img/.config`
- `/build/img/modules-$(cat /build/linux/include/config/kernel.release).erofs`

On the host, these are under:

```text
$HOME/.cache/initos-kernel-dev/img/
```

## Notes

- `kernel_build_tools` is defined in `sidecar/bin/setup-deb`.
- `get_kernel`, `kernel_cfg`, `kernel_build`, and `kernel_pack` are defined in
  `sidecar/bin/setup-kernel`.
- `kernel_cfg_vm` uses `linux/cloud/virtio.fragment`; the old
  `linux/virtio.fragment` path is not used.
- `linux/common.fragment` and `linux/cloud.fragment` currently exist but are not
  merged by the default host `kernel_cfg` path.
