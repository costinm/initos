#!/bin/sh
#
# test_sign_sandbox_inner.sh — Inner runner script for test_sign_bwrap.sh.
# Executed inside the hermetic bubblewrap sandbox.
#

set -eu

SIGNER_PATH="$1"
ARTIFACTS_PATH="$2"
KERNEL_TYPE="$3"
COREUTILS_BIN="$4"
OUT=/out/result

export PATH="${SIGNER_PATH}/bin:${COREUTILS_BIN}:$PATH"
export SECRETS="/out/keys"

if [ "${KERNEL_TYPE}" = "dir" ]; then
    export KERNEL_DIR="/out/kernel"
elif [ "${KERNEL_TYPE}" = "file" ]; then
    export KERNEL_BZIMAGE="/out/kernel/bzImage"
fi

echo "=== Step 1: Generate signing keys ==="
sign.sh sign_init
echo ""

echo "=== Step 2: Sign artifacts ==="
sign.sh artifacts "${ARTIFACTS_PATH}" "${OUT}" "${SECRETS}"
echo ""

# Verify outputs
echo "=== Step 3: Verify outputs ==="
PASS=0
FAIL=0

check_file() {
    if [ -f "$1" ]; then
        echo "  ✅ $1 ($(du -h "$1" | cut -f1))"
        PASS=$((PASS + 1))
    else
        echo "  ❌ MISSING: $1"
        FAIL=$((FAIL + 1))
    fi
}

echo "  --- Signed artifacts ---"
check_file "${OUT}/img/initos.erofs"
check_file "${OUT}/img/initos.erofs.sig"
check_file "${OUT}/img/boot-initos-signed.img"
check_file "${OUT}/boot/EFI/BOOT/BOOTX64.EFI"
check_file "${OUT}/boot/EFI/BOOT/config"
check_file "${OUT}/boot/EFI/BOOT/bzImage"
check_file "${OUT}/boot/EFI/BOOT/initrd.img"

echo ""
echo "  --- Generated keys ---"
check_file "${SECRETS}/PK.crt"
check_file "${SECRETS}/db.key"
check_file "${SECRETS}/db.crt"
check_file "${SECRETS}/image_key.pem"
check_file "${SECRETS}/image_key.pub.b64"

echo ""
if [ "${FAIL}" -eq 0 ]; then
    echo "✅ ALL CHECKS PASSED (${PASS} files verified)"
else
    echo "❌ ${FAIL} CHECKS FAILED (${PASS} passed)"
    exit 1
fi
