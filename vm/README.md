# VM support

There are many ways to run a VM - from 'full disk image with GPT and EFI' to micro-VMs.

This fits the 'minimal' category: it builds a kernel specifically to avoid the complex
`initrd` + module-loading overhead that most distro kernels require. Upstream NixOS
kernels need an initrd for early filesystems and VM block/transport drivers (`erofs`,
`ext4`, `squashfs`, `9p`, `virtiofs`, `virtio`, `virtio-pci`, `virtio-blk`,
`virtio-net`, `tun`, vsock).

This flake keeps a kernel for the no-initrd path.

## Flake outputs

Build with `nix build ./vm#<output>`:

| Output | Contents |
|--------|----------|
| `kernel-cloud` *(default)* | Kernel image (`bzImage`/`vmlinux`), merged config, `modules-cloud.erofs`, static BusyBox — all under `/opt/ssh-mesh-kernel/` |
| `vm-tools` | Symlinks to hypervisors: `cloud-hypervisor`, `ch-remote`, `virtiofsd`, `qemu-system-x86_64`, `crosvm`, `crun` |
| `vm-scripts` | `initos-init-vm` (VM PID-1 init, installed under `/opt/initos/bin/`), `vrun` multi-hypervisor launcher, `run_bwrap.sh` |
| `docker-image` | OCI image containing all of the above plus `iproute2` and `erofs-utils`; published to `ghcr.io/costinm/initos-vm:latest` on main |

## Directory layout

```
vm/
├── flake.nix          # this flake
├── flake.lock
├── base/
│   └── config/
│       ├── config.cloud       # base x86_64 kconfig for cloud VMs
│       └── config.cloud-amd64 # arch seed config
├── fragments/         # incremental kconfig fragments merged at build time
│   ├── common.fragment
│   ├── builtins.fragment
│   ├── filesystems.fragment
│   ├── crypto.fragment
│   ├── containers.fragment
│   ├── net.fragment
│   ├── cloud.fragment
│   └── virtio.fragment
└── bin/               # scripts shipped in the vm-scripts package
    ├── initos-init-vm  # VM PID-1 init (busybox sh; no initrd required)
    ├── vrun            # multi-hypervisor VM launcher (qemu/cloud-hv/crosvm)
    └── run_bwrap.sh    # bwrap-based container launcher helper
```

## Opinionated choices

- Custom kernel with enough built-in drivers to avoid initrd and module loading for
  most use cases (virtiofs, erofs, virtio-blk, virtio-net, vsock all built in).
- Rootfs is an erofs image with minimal userspace (based on BusyBox) and including
  `ssh-mesh` — since that is the primary workload being tested.
- `virtiofs` exposing a shared directory, including startup scripts.
- Console used either as a terminal, or as the main SSH connection. If used as a
  terminal, vsock is used for SSH.

## Network Model

Network is optional — the expectation is that the mesh will apply policies and handle
communication without having to intercept traffic, with application code using UDS or
localhost connections.

VMs that need to test `ssh-mesh` network integration use:
- **vsock** (`AF_VSOCK`): the VM guest connects to the host-side `ssh-mesh` over vsock.
- **nftables / Istio-style capture**: outbound TCP is redirected in the VM by nftables,
  matching Istio's iptables capture approach; `mesh-init` manages the rules.
- **mesh-init**: owns the network namespace setup and service lifecycle inside the VM.

The `tun`/`passt` approach (pasta/passt userspace networking) was evaluated and
dropped — tests showed it to be slower and more complex.

## Hypervisors

`vrun` auto-detects the best available hypervisor (prefers crosvm → cloud-hypervisor
→ qemu when KVM is available, falls back to qemu via TCG). Override with `virt=ch`,
`virt=qemu`, or `virt=crosvm`.

The `vm-tools` package and `docker-image` output bundle all three hypervisors. The
kernel `kernel-cloud` package is intentionally kept separate so it can be copied to
another machine without pulling hypervisor closures along.

## Script Origins and Test Location

`bin/initos-init-vm`, `bin/vrun`, and `bin/run_bwrap.sh` were originally developed in
`github.com/costinm/ssh-mesh`. They have been moved here to keep VM-specific tooling
co-located with the kernel it targets and to reduce the scope of `ssh-mesh` to SSH /
mesh-init and associated mesh binaries.

VM test scripts (`test_vm_qemu_echo.sh`, `test_vm_vrun_cloud_hypervisor_echo.sh`,
`test_vm_vrun_crosvm_echo.sh`, `test_vm_microvm_echo.sh`, `test_vm_echo_latency.sh`,
`test_vm_mesh_init_root_hardening.sh`) and the `microvm-echo/` Nix flake have also
been moved from `ssh-mesh/tests/` to `initos/tests/`. The `ssh-mesh` repo no longer
contains VM execution tests or build targets for EROFS rootfs images.
