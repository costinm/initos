#!/bin/sh

# executed by initos-init inside QEMU via 9p share
#
# Tests: fscrypt with FSCRYPT_KEY env var, fscrypt with TPM,
# and anti-replay (PCR extend).

echo "===== Hello World from initos! ====="
echo "Kernel: $(uname -r)"
echo "Init PID: $$"
env
set -x

echo "=== TPM2 TEST ==="

# Create primary key
initos primary
echo "primary exit=$?"
cat /z/initos/tpm/tpm_primary

# Seal a test secret (64 bytes for AES-256-XTS)
# We test with INITOS_PUB_KEY to verify the recovery file is generated.
export INITOS_PUB_KEY="GOmR9GEy3xbI/4ybZDnv9coSOuD4kMkEkQcGGsbfkus="
initos seal "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
echo "seal exit=$?"
cat /z/initos/tpm/tpm_handle

if [ -f /z/initos/tpm/recovery ]; then
    echo "Recovery file created successfully ($(wc -c < /z/initos/tpm/recovery) bytes)"
    
    # Use the pre-compiled initos-recover binary copied to the 9p mount (/x)
    RECOVER_BIN="/x/initos-recover"
    if [ ! -x "$RECOVER_BIN" ]; then
        echo "=== RECOVERY FAIL (initos-recover binary not found or not executable) ==="
        ls -la /x/initos-recover || true
    fi
    
    # Run recovery (use the RAW private key seed copied to the 9p mount)
    if [ -f /x/image_key.raw ]; then
        REC_OUT=$($RECOVER_BIN /z/initos/tpm/recovery /x/image_key.raw)
        echo "Recovered payload: [$REC_OUT]"
        if [ "$REC_OUT" = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ]; then
            echo "=== RECOVERY OK ==="
        else
            echo "=== RECOVERY FAIL (mismatch) ==="
        fi
    else
        echo "=== RECOVERY FAIL (private key raw seed missing) ==="
    fi
else
    echo "=== RECOVERY FAIL (no file) ==="
fi

# ─── Test 1: fscrypt with FSCRYPT_KEY env var (no TPM needed) ────────────────
echo "=== FSCRYPT ENV KEY TEST ==="
FSCRYPT_DIR=/z/test_env_encrypted
mkdir -p "${FSCRYPT_DIR}"

# Use FSCRYPT_KEY env var — key gets padded to 64 bytes internally
FSCRYPT_KEY="my-user-password" initos fscrypt-setup "${FSCRYPT_DIR}"
echo "fscrypt-setup (env) exit=$?"

# Write and read back
echo "env-secret-data" > "${FSCRYPT_DIR}/test.txt"
echo "write exit=$?"
sync
EDATA=$(cat "${FSCRYPT_DIR}/test.txt" 2>&1)
echo "FSCRYPT ENV READ: [${EDATA}]"

if [ "${EDATA}" = "env-secret-data" ]; then
    echo "=== FSCRYPT ENV KEY OK ==="
else
    echo "=== FSCRYPT ENV KEY FAIL (got: ${EDATA}) ==="
    ls -la "${FSCRYPT_DIR}/" 2>&1
fi

# ─── Test 2: fscrypt with TPM unseal ────────────────────────────────────────
echo "=== FSCRYPT TPM TEST ==="
FSCRYPT_DIR2=/z/test_tpm_encrypted
mkdir -p "${FSCRYPT_DIR2}"

# This calls unseal internally (first unseal)
initos fscrypt-setup "${FSCRYPT_DIR2}"
echo "fscrypt-setup (tpm) exit=$?"

echo "tpm-secret-data" > "${FSCRYPT_DIR2}/test.txt"
sync
TDATA=$(cat "${FSCRYPT_DIR2}/test.txt" 2>&1)
echo "FSCRYPT TPM READ: [${TDATA}]"

if [ "${TDATA}" = "tpm-secret-data" ]; then
    echo "=== FSCRYPT TPM OK ==="
else
    echo "=== FSCRYPT TPM FAIL (got: ${TDATA}) ==="
    ls -la "${FSCRYPT_DIR2}/" 2>&1
fi

# ─── Test 3: anti-replay (second unseal should fail) ────────────────────────
echo "=== ANTI-REPLAY TEST ==="
initos lock_tpm
echo "lock_tpm exit=$?"

RESULT2=$(initos unseal 2>&1)
rc=$?
echo "second unseal exit=$rc"
if [ $rc -ne 0 ]; then
    echo "=== ANTI-REPLAY OK (second unseal correctly rejected) ==="
else
    echo "=== ANTI-REPLAY FAIL (second unseal should have failed) ==="
fi

echo "=== ALL TESTS COMPLETE ==="
