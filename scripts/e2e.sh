#!/usr/bin/env bash
#
# e2e.sh — Boot the initos test image set with QEMU.
#
# Boot flow:
#   kernel → initrd(initos) → finds STATE partition → verifies ROOT-A.img → switch_root
#
# Usage: ./scripts/e2e.sh [test_dir]     # Test with ext4 STATE partition
#
#
# Expects test_dir (default: target/test) to contain:
#   state.ext4   - STATE partition (ext4) with ROOT-A.img + sig
#   state.btrfs  - STATE partition (btrfs) with ROOT-A.img + sig
#   initrd.img   - initrd with initos binary
#   pub_key.hex  - ed25519 public key
#
# Kernel: prebuilt/boot/EFI/LINUX/bzImage
# Env: INITOS_FS=ext4 or btrfs, defaults ext4
#
# Requires: qemu-system-x86_64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL="${PROJECT_ROOT}/prebuilt/boot/EFI/LINUX/bzImage"
TEST_DIR="${PROJECT_ROOT}/target/test"
TIMEOUT=${QEMU_TIMEOUT:-30}
INITOS_FS="${INITOS_FS:-ext4}"

STATE_IMG="${TEST_DIR}/disk.img"

INITRD_IMG="${TEST_DIR}/initrd.img"
PUB_KEY_FILE="${TEST_DIR}/pub_key.hex"

# Validate inputs
if [[ ! -f "${KERNEL}" ]]; then
	echo "ERROR: kernel not found at ${KERNEL}"
	exit 1
fi

if [[ ! -f "${STATE_IMG}" ]]; then
	echo "ERROR: STATE partition not found at ${STATE_IMG}"
	echo "Run with --build or: bash scripts/build.sh && bash scripts/mkrootfs.sh"
	exit 1
fi

if [[ ! -f "${INITRD_IMG}" ]]; then
	echo "ERROR: initrd not found at ${INITRD_IMG}"
	echo "Run with --build or: bash scripts/build.sh && bash scripts/mkrootfs.sh"
	exit 1
fi

PUB_KEY=""
if [[ -f "${PUB_KEY_FILE}" ]]; then
	PUB_KEY=$(cat "${PUB_KEY_FILE}")
fi

echo "=== Starting QEMU (${INITOS_FS} test) ==="
echo "  Kernel:    ${KERNEL}"
echo "  Initrd:    ${INITRD_IMG}"
echo "  STATE:     ${STATE_IMG}"
echo "  Filesystem: ${INITOS_FS}"
echo "  PubKey:    ${PUB_KEY:-<not set>}"
echo ""

# Build kernel cmdline
# initos looks for INITOS_OP, INITOS_PUB_KEY, INITOS_IMG, INITOS_DATA, INITOS_FS via env vars
# Kernel cmdline sets environment for PID 1 (init/rdinit)
CMDLINE="console=ttyS0 loglevel=7 rw"
CMDLINE="${CMDLINE} rdinit=/init"
CMDLINE="${CMDLINE} INITOS_OP=boot"
CMDLINE="${CMDLINE} INITOS_DATA=STATE"
CMDLINE="${CMDLINE} INITOS_IMG=/img/ROOT-A.img"
CMDLINE="${CMDLINE} INITOS_FS=${INITOS_FS}"
if [[ -n "${PUB_KEY}" ]]; then
	CMDLINE="${CMDLINE} INITOS_PUB_KEY=${PUB_KEY}"
fi
QEMU_ARGS=()

if [[ -n "${OVMF:-}" ]]; then
	QEMU_ARGS+=(-drive "if=pflash,format=raw,file=${OVMF}")
else
	QEMU_ARGS+=(
		-kernel "${KERNEL}"
		-initrd "${INITRD_IMG}"
		-append "${CMDLINE}"
	)
fi

QEMU_ARGS+=(
	-drive "file=${STATE_IMG},format=raw,if=virtio"
	-m 512M
	-smp 2
	-nographic
	-no-reboot
	-nodefaults
	-chardev stdio,mux=on,id=char0
	-serial chardev:char0
	-monitor chardev:char0
)

# Use KVM if available
if [[ -w /dev/kvm ]]; then
	QEMU_ARGS+=(-enable-kvm -cpu host)
else
	echo "WARNING: KVM not available, using emulation (slower)"
	QEMU_ARGS+=(-cpu qemu64)
fi
# Run with timeout to avoid hanging
if command -v timeout &>/dev/null; then
	timeout --foreground "${TIMEOUT}" qemu-system-x86_64 "${QEMU_ARGS[@]}" || {
		rc=$?
		if [[ $rc -eq 124 ]]; then
			echo ""
			echo "=== QEMU timed out after ${TIMEOUT}s ==="
			exit 1
		fi
		# Exit code from poweroff is expected
		true
	}
else
	qemu-system-x86_64 "${QEMU_ARGS[@]}"
fi

echo ""
echo "=== QEMU session complete ==="
