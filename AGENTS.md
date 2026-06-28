# initos Agent Notes

This file is for future coding agents working in this repository. Keep it
focused on the project as a whole. Area-specific notes live in separate files.

## Project Scope

`initos` is a Rust and Nix project for minimal verified Linux boot and early
initialization. The project includes:

- a Rust `initos` binary used in initrd/PID 1 flows;
- a Rust EFI loader for verified EFI boot on physical hosts;
- Nix builds for signed/unsigned artifacts, kernels, root images, initrds
- shell tooling for host setup, containerized builds and
  test harnesses;

The main security model is verified boot and verified root handoff: UEFI Secure Boot verifies the EFI loader, the loader verifies kernel/config/initrd material, and the init path verifies or mounts read-only OS images before handing off to the target system.

## Area Notes

- Kernel build workflow: `linux/AGENT.md`

Open the area note before doing detailed work in that area.

## Repository Conventions

- Prefer shell for harnesses and Python or Rust when a real program is needed.
- Nix is used for release and to provide a hermetic build environment
- scripts/build.sh is used for iterative development, expects either nix or debian with all deps installed.
- The user expects verification against the real failing path, built output,
  VM log, or harness. Prefer running the relevant smoke test over stopping at a plausible static explanation.
- The worktree may contain user edits. Do not revert unrelated changes.

## Main Components

Rust code:

```text
src/main.rs        CLI and init entry behavior
src/cmd.rs         command dispatch
src/mount.rs       early mount, STATE lookup, switch_root helpers
src/verify.rs      signature verification
src/verity.rs      fs-verity measurement helpers
src/tpm2.rs        TPM2 sealing/unsealing helpers
src/fscrypt.rs     fscrypt setup helpers
src/bin/efi.rs     EFI loader binary
src/efi.rs         EFI verification/loading support
```

Nix entry points:

```text
flake.nix
linux/flake.nix
```

Important tests and harnesses:

```text
tests/run_qemu.sh
tests/verify_test.rs
tests/tpm2_tests.rs
tests/test_encrypt_decrypt.sh
sidecar/bin/sign.sh
```

## Signing Workflow

`sidecar/bin/sign.sh` handles signing of boot images, kernel modules, and firmware.

Key types:
- **db.key/db.crt** (required): UEFI Secure Boot database key for signing EFI binaries and computing fs-verity digests
- **image_key.pem** (optional): Ed25519 key for fs-verity image signing; generated via `generate_ed25519_keypair()` if needed

Environment variables:
- **NIX_PROFILE**: Path to the Nix profile directory (default: `$PWD/target/nix/profiles/profile`)
- **SECRETS**: Path to the secrets directory (default: `/var/run/secrets/uefi-keys`)

Signing workflow:
1. `nix profile upgrade initos --profile target/nix/profiles/profile` - builds the Nix profile with kernel and artifacts
2. `export PATH="target/nix/profiles/profile/bin:$PATH"` - add profile bin to PATH
3. `sign.sh` - runs the default `artifacts` command, signing everything

The script auto-detects kernel and artifact locations from the Nix profile.

## Common Verification Commands

Rust checks:

```sh
cargo check
cargo test -p initos
```

Nix profile upgrade and signing:

```sh
nix profile upgrade initos --profile target/nix/profiles/profile
export PATH="target/nix/profiles/profile/bin:$PATH"
sign.sh
```

Nix artifact/profile checks:


EFI/QEMU host-boot harness:

```sh
TIMEOUT=90 tests/run_qemu.sh
```

When testing shell harness edits:

```sh
bash -n path/to/script
```
