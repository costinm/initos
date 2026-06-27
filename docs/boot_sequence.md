# Initrd Boot Sequence

This document describes the `initos boot` path implemented in `src/boot.rs`.
Update it whenever the boot environment variables, fixed paths, mount order,
image verification rules, unlock behavior, or init selection logic changes.

## Environment Variables on kernel command line

`INITOS_IMG`

- Root EROFS image path relative to the mounted state filesystem when no encrypted root directory is selected.
- Default: `/img/initos.erofs`.
- Leading `/` is stripped before joining with `/z`, so the default resolves to `/z/img/initos.erofs`.
- Ignored when `/z/c/roots/${INITOS_ROOT}` exists.
- Passed through to the final process at `switch_root`.
- Temp - may be removed.

`INITOS_DATA`

- State block device selector.
- Default: `STATE`.
- If the value starts with `/dev/`, it is used as a direct block device path.
- Otherwise it is resolved by filesystem label under `/dev/disk/by-label`, by ext4 filesystem label scanned from `/sys/class/block`, or by partition name from `uevent`.
- The special value `USTATE` waits up to 20 seconds for the device to appear.
- Passed through to the final process at `switch_root`.

`INITOS_ROOT`

- Encrypted root directory name under `/z/c/roots`.
- Default: `ROOTA`.
- If `/z/c/roots/${INITOS_ROOT}` exists, it is recursively bind-mounted as `/sysroot`.
- If it does not exist, the boot path falls back to `INITOS_IMG`.
- Passed through to the final process at `switch_root`.

`INITOS_INIT`

- Explicit init path to execute after `switch_root`.
- If set, no init auto-detection is performed and no extra arguments are added.
- Passed through to the final process at `switch_root`.

`INITOS_EFI_PATH`

- Optional efivarfs base path.
- Default: `/sys/firmware/efi/efivars`.
- Used to read the EFI `SecureBoot` variable for verified-mode detection.
- Verified mode is determined solely from EFI SecureBoot; if the variable cannot be read, boot runs in development (unverified) mode.
- Passed through to the final process at `switch_root`.
- Temp - may be removed.

## Passed to the next step

`INITOS_BOOT_ERROR`

- Set only when the boot sequence fails in development mode.
- Contains the boot error string with NUL bytes escaped as `\0`.
- Used by the initrd fallback `/opt/initos/bin/initos-initrd`.

All environment variables present in the `initos boot` process are passed to the
final process by `switch_root_with_args`, which builds an explicit `execve`
environment from `std::env::vars_os()`.

## Fixed Paths

Initial initrd mounts and devices:

- `/proc`: initrd procfs mount.
- `/sys`: initrd sysfs mount, also used for block-device scanning.
- `/sys/firmware/efi/efivars`: initrd efivarfs mount for SecureBoot detection when available.
- `/dev`: initrd devtmpfs mount.
- `/dev/disk/by-label/<label>`: preferred label lookup path.
- `/dev/tpmrm0`: TPM resource manager device required for TPM unlock attempts.
- `/dev/loop-control` and `/dev/loop<N>`: loop device setup for EROFS images.
- `/proc/sys/kernel/osrelease`: preferred kernel release source.

Development fallback in case of errors before switch_root:

- `/opt/initos/bin/initos-initrd`

State filesystem:

- `/z`: mounted state filesystem selected by `INITOS_DATA`.
- `/z/img/initos.erofs`: default root image.
- `/z/img/firmware.erofs`: preferred firmware image location.
- `/z/img/modules-<kernel>.erofs`: preferred modules image location.
- `/z/img/*.erofs.sig`: signature files consumed by image verification.
- `/z/c`: encrypted fscrypt state directory.
- `/z/c/home`: sentinel used to decide whether `/z/c` is unlocked.
- `/z/c/home/root`: optional source for the root user's home directory bind.
- `/z/c/nix`: optional source for the Nix store/profile bind.
- `/z/c/roots/<name>`: optional encrypted root selected by `INITOS_ROOT`.
- `/z/c/initos/init`: first auto-detected init path, when present.
- `/z/initos/c.age`: optional age-encrypted fscrypt key material.
- `0x81000000`: fixed TPM persistent primary handle.
- `0x81001002`: fixed TPM persistent sealed handle for development/unverified mode.
- `0x81001003`: fixed TPM persistent sealed handle for Secure Boot mode.

Fallback image lookup paths:

- `/img/firmware.erofs`
- `/img/modules-<kernel>.erofs`
- `/data/img/firmware.erofs` - deprecated, old
- `/data/img/modules-<kernel>.erofs` - old

New root:

- `/sysroot`: root mount point before `switch_root`.
- `/sysroot/z`: bind mount of the state filesystem.
- `/sysroot/mnt`: tmpfs used for host image mounts.
- `/sysroot/mnt/firmware`: mounted firmware EROFS image.
- `/sysroot/mnt/modules/<kernel>`: mounted modules EROFS image.
- `/sysroot/lib/firmware` or `/sysroot/usr/lib/firmware`: optional firmware bind target, with `/lib` symlinks resolved.
- `/sysroot/lib/modules` or `/sysroot/usr/lib/modules`: optional modules bind target, with `/lib` symlinks resolved.
- `/sysroot/home`: optional target for `/z/c/home`.
- `/sysroot/root`: optional target for `/z/c/home/root`.
- `/sysroot/nix`: optional target for `/z/c/nix`.
- `/sysroot/proc`: procfs for the final root.
- `/sysroot/sys`: sysfs for the final root.
- `/sysroot/dev`: devtmpfs for the final root.
- `/sysroot/dev/pts`: devpts for the final root.
- `/sysroot/dev/shm`: tmpfs for the final root.
- `/sysroot/run`: tmpfs for the final root.
- `/sysroot/sys/fs/cgroup`: cgroup2 for the final root.
- `/sysroot/tmp`: tmpfs for the final root - TODO: will be real disk

Auto-detected init paths:

- `/z/c/initos/init`
- `/opt/initos/bin/initos-init`
- `/sbin/init`
- `/lib/systemd/systemd`


## Boot Steps

1. Read `INITOS_IMG`, defaulting to `/img/initos.erofs`.
2. Read `INITOS_DATA`, defaulting to `STATE`.
3. Read the running kernel release from `/proc/sys/kernel/osrelease`; if that fails, use `uname`. TODO: uname may not be present.
4. Mount initrd pseudo-filesystems:
   - `proc` at `/proc`
   - `sysfs` at `/sys`
   - `efivarfs` at `/sys/firmware/efi/efivars`
   - `devtmpfs` at `/dev`
5. Detect verified mode from EFI SecureBoot. If the `SecureBoot` variable cannot be read, boot runs in development (unverified) mode.
6. Resolve the state block device selected by `INITOS_DATA`.
7. Mount the state device as ext4 at `/z`.
8. Unlock `/z/c` if needed.
9. Mount the root filesystem at `/sysroot`.
10. Bind `/z` to `/sysroot/z`.
11. Mount host firmware and module images under `/sysroot/mnt`.
12. Bind host firmware and module mounts into rootfs library directories when those directories exist.
13. Bind selected encrypted state directories into the new root when both source and target directories exist.
14. Mount system filesystems under `/sysroot`.
15. Select the final init.
16. Move `/sysroot` to `/`, chroot into it, and execute the selected init with all current environment variables.

## State Device Selection

When `INITOS_DATA` is not `USTATE`, the device is resolved once.

When `INITOS_DATA=USTATE`, boot waits up to 20 seconds, retrying once per
second, before failing.

Device resolution order:

1. Direct `/dev/...` path.
2. `/dev/disk/by-label/<INITOS_DATA>`.
3. Ext4 filesystem label scanned from `/sys/class/block`.
4. Partition name read from each block device `uevent`.

Labels beginning with `USB` are retried up to 10 times by the generic label
lookup helper.

## `/z/c` Unlock Conditions

If `/z/c` does not exist, no encrypted-state unlock is attempted.

If `/z/c/home` exists, `/z/c` is considered already unlocked:

- In verified mode, boot fails.
- In development mode, boot logs that `/z/c` is already unlocked and continues.

If `/z/c/home` does not exist, boot tries TPM unlock first when this condition
is true:

- `/dev/tpmrm0` exists.

TPM unlock:

1. Use handle `0x81001003` when EFI SecureBoot is enabled.
2. Use handle `0x81001002` when EFI SecureBoot is disabled or unavailable and the fallback verified-mode check is false.
3. Open the TPM device.
4. Start a policy session.
5. Apply the PCR policy.
6. Unseal key material from the TPM.
7. Require a `secc:` prefix in Secure Boot mode or a `devc:` prefix in development mode.
8. Strip the prefix.
9. Use the stripped TPM material directly as the fscrypt key.
10. Add the fscrypt key to `/z/c`.
11. Require `/z/c/home` to exist after adding the key.

TPM sealed value format:

- Development/unverified sealed values start with `devc:`.
- Secure Boot sealed values start with `secc:`.
- The prefix is stripped after unseal and is not part of the fscrypt or age decrypt key material.
- TPM unlock does not read or decrypt `/z/initos/c.age`.

TPM setup commands:

- Create or replace the persistent primary handle:
  `initos primary`
- Create or replace the development/unverified sealed handle:
  `initos seal --dev --handle 1002 <SECRET>`
- Create or replace the Secure Boot sealed handle:
  `initos seal --secure --handle 1003 <SECRET>`
- The full-handle forms are also accepted:
  `initos seal --dev --handle 0x81001002 <SECRET>`
  `initos seal --secure --handle 0x81001003 <SECRET>`
- Without `--handle`, `initos seal --dev <SECRET>` uses `0x81001002` and `initos seal --secure <SECRET>` uses `0x81001003`.
- Without `--dev` or `--secure`, `initos seal <SECRET>` reads EFI SecureBoot and chooses the matching handle and prefix. If EFI SecureBoot cannot be read, it uses the development/unverified handle.
- `initos unseal` follows the same auto-detection rule.
- `initos unseal --dev --handle 1002` and `initos unseal --secure --handle 1003` can be used to test explicit handles.

If TPM unlock is unavailable or fails, password unlock is attempted. The
password fallback is the only unlock path that uses `/z/initos/c.age`.

Password unlock:

1. Prompt up to three times.
2. Use `Enter host unlock password: ` when `/z/initos/c.age` exists.
3. Use `Enter crypt password: ` when `/z/initos/c.age` does not exist.
4. Ignore empty passwords and continue to the next attempt.
5. If `/z/initos/c.age` exists, decrypt it with the entered password; otherwise use the entered password bytes directly.
6. Add the resulting fscrypt key to `/z/c`.
7. Require `/z/c/home` to exist after adding the key.
8. Fail after three unsuccessful attempts.

Any unlock failure is handled by the top-level boot error policy.

## Root Filesystem Selection

The encrypted root check happens before the root EROFS image is used.

1. Read `INITOS_ROOT`, defaulting to `ROOTA`.
2. Check `/z/c/roots/${INITOS_ROOT}`.
3. If it exists, recursively bind-mount it at `/sysroot` and skip `INITOS_IMG`.
4. If it does not exist, resolve `INITOS_IMG` under `/z`.
5. In verified mode, verify the image before mounting.
6. Mount the image read-only as EROFS at `/sysroot`.

## Image Verification

Image verification runs only in verified mode (EFI SecureBoot enabled). It uses
the UEFI `db` certificates to verify per-image signatures (see `verify_image_db`
in `src/verify.rs`).

The following images are verified before mounting:

- Root image from `INITOS_IMG`, unless an encrypted root directory is used.
- `firmware.erofs`, if found.
- `modules-<kernel>.erofs`, if found.

Verification uses `crate::verify::verify_image`, which includes the fs-verity
measurement/signature flow used by the image verifier.

If an image is absent, firmware and modules mounting is skipped for that image.
Missing host firmware or modules images are not fatal by themselves.

### Missing Signatures In Verified Mode

In verified mode, a missing signature file is a hard boot failure. This applies
to both the standard image path and the partitioned image path: when a boot
partition ID is extracted from EFI variables and the corresponding partitioned
image file exists on STATE but has no matching `.sig`, the boot fails rather
than silently falling back to the unpartitioned default image. This prevents an
attacker with write access to STATE from forcing the use of a different
(possibly older) image by deleting a partitioned signature.

In development mode (Secure Boot disabled), missing signatures are not fatal —
the image is still mounted without verification. This is acceptable because
development mode is already unverified by definition.

## Firmware And Modules Mounting

Before mounting host images, `/sysroot/mnt` is mounted as tmpfs.

Firmware:

1. Look for `firmware.erofs` in `/z/img`, `/img`, then `/data/img`.
2. Verify it in verified mode.
3. Mount it read-only as EROFS at `/sysroot/mnt/firmware`.

Modules:

1. Read the kernel release.
2. Look for `modules-<kernel>.erofs` in `/z/img`, `/img`, then `/data/img`.
3. Verify it in verified mode.
4. Mount it read-only as EROFS at `/sysroot/mnt/modules/<kernel>`.

After image mounts, the boot path attempts rootfs library binds:

- Bind `/sysroot/mnt/firmware` to the resolved root path for `lib/firmware`.
- Bind `/sysroot/mnt/modules` to the resolved root path for `lib/modules`.
- Skip each bind when the resolved target directory does not exist.

The resolver follows absolute and relative symlinks under `/sysroot`, so a
rootfs where `/lib` points to `/usr/lib` binds into `/sysroot/usr/lib/...`.

## Encrypted State Binds

Each bind is attempted only when both source and target are directories:

- `/z/c/home` to `/sysroot/home`
- `/z/c/home/root` to `/sysroot/root`
- `/z/c/nix` to `/sysroot/nix`

Missing source or target directories are logged and skipped.

## System Filesystems

The following filesystems are mounted under `/sysroot` before `switch_root`:

- `proc` at `/sysroot/proc`
- `sysfs` at `/sysroot/sys`
- `efivarfs` at `/sysroot/sys/firmware/efi/efivars` when available
- `devtmpfs` at `/sysroot/dev`
- `devpts` at `/sysroot/dev/pts`
- `tmpfs` at `/sysroot/dev/shm`
- `tmpfs` at `/sysroot/run`
- `cgroup2` at `/sysroot/sys/fs/cgroup`
- `tmpfs` at `/sysroot/tmp`

## Init Selection

If `INITOS_INIT` is set, it is used directly and no extra arguments are added.

If `INITOS_INIT` is unset, candidates are checked in this order:

1. `/z/c/initos/init`, checked before `switch_root` as `/z/c/initos/init`.
2. `/opt/initos/bin/initos-init`, checked inside `/sysroot`.
3. `/sbin/init`, checked inside `/sysroot`.
4. `/lib/systemd/systemd`, checked inside `/sysroot` through the symlink-aware resolver.

When systemd is selected, `--system` is passed as the first argument.

If no init is found, boot fails.

## Switch Root And Final Exec

The selected init is executed through `switch_root_with_args`.

The handoff sequence is:

1. `chdir("/sysroot")`
2. `mount(".", "/", MS_MOVE)`
3. `chroot(".")`
4. `chdir("/")`
5. `execve(init_path, argv, envp)`

`argv[0]` is the selected init path. Additional args are only currently used
for systemd, where `--system` is appended.

`envp` is built from every current process environment variable. This preserves
kernel-command-line variables such as `INITOS_DATA`, `INITOS_ROOT`,
`INITOS_IMG`, and `INITOS_INIT` for the final process.

## Error Handling

All boot sequence errors are caught by the top-level boot runner.

Development mode:

- Set `INITOS_BOOT_ERROR`.
- Execute `/opt/initos/bin/initos-initrd` in the initrd environment.
- If the fallback exec fails, exit with status 1.

Verified mode:

- Log the boot failure.
- Wait 10 seconds.
- Exit with status 1.

## Anti-Rollback And Key Rotation

initos does not implement TPM-based monotonic counters or version binding:
an older signed image plus its matching `.sig` (still validly signed by the
owner key) can be copied onto STATE and booted, because PCR 7 only reflects
Secure Boot state, not the image identity. A/B boot partitions (BOOTA/BOOTB)
amplify the impact of a rollback mistake.

The plan is to mitigate this by **periodically rotating the signing keys**:

- The UEFI `db` key and the image Ed25519/RSA signing key are regenerated on a
  schedule (nominally every N months).
- New images are signed only with the current key; the previous key is retired
  and no longer used to sign new images.
- A retired key prevents new images from being booted after the firmware/db is
  updated to the new key — old images signed with the retired key will no longer
  verify.
- This bounds the window during which a stolen/leaked signing key can produce
  bootable images.

Revocation does **not** rely on the UEFI `dbx` (forbidden signature database):
initos does not read or consult `dbx`. Key rotation is the sole revocation
mechanism. Operators are expected to retire old keys by updating `db` on the
host rather than by maintaining a `dbx` denylist.

## STATE Filesystem Writable Surface

The STATE ext4 partition is mounted read-write during early boot so that the
fscrypt key can be added to the filesystem keyring (which requires a writable
mount). The partition holds signed EROFS images, their `.sig` files, and the
encrypted `c.age` key material.

Risk analysis:

- **Verified mode:** an attacker with write access to STATE can delete
  `.sig` files, causing the boot to **fail hard** (see "Missing Signatures In
  Verified Mode" above). This is a denial-of-service, not a trust bypass: the
  boot refuses to proceed without a valid signature. Reinstalling the missing
  `.sig` from a signed artifact restores normal operation.
- **Development mode:** STATE is writable and images are not verified, so a
  writable STATE is not an additional risk — development mode is already
  unverified by definition.
- fs-verity protects verified files' contents at the block level; only file
  *presence* and *metadata* (which `.sig` files exist) are influenced by a
  writable STATE, and missing signatures are fatal in verified mode.
