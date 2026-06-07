#!/usr/bin/env bash
set -euo pipefail

# This script assembles the initos artifacts.
# It is designed to be runnable both inside a Nix build and independently.

OUT="${OUT:-$out}"
TMPDIR="${TMPDIR:-/tmp}"
WITH_KERNELS="${WITH_KERNELS:-0}"

# If running outside Nix, try to infer defaults from the repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Resolve locations
CARGO_TOML="${CARGO_TOML:-$REPO_ROOT/Cargo.toml}"
SIDECAR_BIN="${SIDECAR_BIN:-$REPO_ROOT/sidecar/bin}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$REPO_ROOT/scripts}"
PREBUILT_DIR="${PREBUILT_DIR:-$REPO_ROOT/prebuilt}"
SIGN_SH_LIB="${SIGN_SH_LIB:-$REPO_ROOT/sidecar/bin/sign.sh}"

# If these binaries are not passed, check typical cargo target dirs
if [ -z "${INITOS_BIN:-}" ]; then
  if [ -f "$REPO_ROOT/target/x86_64-unknown-linux-musl/release/initos" ]; then
    INITOS_BIN="$REPO_ROOT/target/x86_64-unknown-linux-musl/release/initos"
  else
    echo "ERROR: INITOS_BIN not set and not found in target dir" >&2
    exit 1
  fi
fi

if [ -z "${EFI_BIN:-}" ]; then
  if [ -f "$REPO_ROOT/target/x86_64-unknown-uefi/release/efi.efi" ]; then
    EFI_BIN="$REPO_ROOT/target/x86_64-unknown-uefi/release/efi.efi"
  else
    echo "ERROR: EFI_BIN not set and not found in target dir" >&2
    exit 1
  fi
fi

if [ -z "${USE_BUSYBOX:-}" ]; then
  # Try to find busybox on system or default
  if [ -f "$PREBUILT_DIR/bin/busybox" ]; then
    USE_BUSYBOX="$PREBUILT_DIR/bin/busybox"
  elif which busybox >/dev/null 2>&1; then
    USE_BUSYBOX="$(which busybox)"
  else
    echo "ERROR: USE_BUSYBOX not set and busybox command not found" >&2
    exit 1
  fi
fi

# Build in temp dir
WRITABLE="$TMPDIR/build"
rm -rf "$WRITABLE" # Ensure clean state if run multiple times
mkdir -p "$WRITABLE"/{prebuilt/boot/EFI/BOOT,prebuilt/testdata,prebuilt/bin,sidecar/bin}

cp -R "$PREBUILT_DIR/testdata/." "$WRITABLE/prebuilt/testdata/"
cp -R "$PREBUILT_DIR/boot/." "$WRITABLE/prebuilt/boot/"
ln -sf "$SCRIPTS_DIR" "$WRITABLE/scripts"

cp -R "$SIDECAR_BIN/." "$WRITABLE/sidecar/bin/"
chmod 755 "$WRITABLE/sidecar/bin/"*
cp "$CARGO_TOML" "$WRITABLE/Cargo.toml"

BUILD_SRC="$WRITABLE"
BUILD_OUT="$WRITABLE/target"
mkdir -p "$BUILD_OUT"/{disks/state/img,disks/boot/EFI/BOOT,test/img}

mkdir -p "$BUILD_OUT"/x86_64-unknown-linux-musl/release
cp "$INITOS_BIN" "$BUILD_OUT/x86_64-unknown-linux-musl/release/initos"
mkdir -p "$BUILD_OUT"/x86_64-unknown-uefi/release
cp "$EFI_BIN" "$BUILD_OUT/x86_64-unknown-uefi/release/efi.efi"
cp "$USE_BUSYBOX" "$WRITABLE/prebuilt/bin/busybox"

# Run build.sh functions — must call individually
export IMG_DIR="$BUILD_OUT/disks/state/img"
for fn in build_initos build_boot; do
  echo "=== build.sh $fn ==="
  src="$BUILD_SRC" out="$BUILD_OUT" \
    bash "$BUILD_SRC/scripts/build.sh" "$fn" 2>&1
done
# ── Assemble into OUT ──
mkdir -p "$OUT"/img "$OUT"/bin "$OUT"/boot/EFI/BOOT

# initos rootfs
if [ -f "$BUILD_OUT/disks/state/img/initos.erofs" ]; then
  cp "$BUILD_OUT/disks/state/img/initos.erofs" "$OUT"/img/initos.erofs
fi

# Expanded unsigned EFI System Partition content
cp -R "$BUILD_OUT/disks/boot/." "$OUT"/boot/

if [ "$WITH_KERNELS" = "1" ] || [ "$WITH_KERNELS" = "true" ]; then
  if [ -n "${KERNEL_HOST_DIR:-}" ]; then
    for m in "$KERNEL_HOST_DIR"/img/modules-*.erofs; do
      [ -f "$m" ] && cp "$m" "$OUT"/img
    done
  fi

  # Firmware
  if [ -n "${FIRMWARE_EROFS_DIR:-}" ] && [ -f "$FIRMWARE_EROFS_DIR/img/firmware.erofs" ]; then
    cp "$FIRMWARE_EROFS_DIR/img/firmware.erofs" "$OUT"/img/firmware.erofs
  fi
fi

# bin/
# Copy all sidecar scripts/binaries to bin/
cp -R "$BUILD_SRC"/sidecar/bin/. "$OUT"/bin/
# Copy initos binary
cp "$INITOS_BIN" "$OUT"/bin/initos
chmod 755 "$OUT"/bin/*

if find "$OUT" -type f \( -name '*.sig' -o -name '*signed*.img' \) | grep -q .; then
  echo "ERROR: unsigned artifact output contains signed artifacts" >&2
  find "$OUT" -type f \( -name '*.sig' -o -name '*signed*.img' \) >&2
  exit 1
fi

echo "initos-signer:"
find "$OUT" -type f | sort | sed "s|$OUT/|  |"
