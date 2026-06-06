#!/usr/bin/env bash
#
# test_sign_docker.sh — Validate initos-signer docker image under podman.
# Mounts host keys and bzImage, runs the container to produce signed boot/STATE files,
# and verifies they match the host-generated outputs.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOCKER_TAR="${PROJECT_ROOT}/result-docker"
KEYS_DIR="${PROJECT_ROOT}/prebuilt/testdata/uefi-keys"
BZIMAGE_FILE="${PROJECT_ROOT}/prebuilt/boot/EFI/BOOT/bzImage"
HOST_OUT_DIR="${PROJECT_ROOT}/target"
DOCKER_OUT_DIR="${PROJECT_ROOT}/target/test-docker-out"

# 1. Prerequisite Checks
if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found." >&2
    exit 1
fi

if [[ ! -d "${KEYS_DIR}" ]]; then
    echo "ERROR: keys directory not found: ${KEYS_DIR}" >&2
    exit 1
fi

if [[ ! -f "${BZIMAGE_FILE}" ]]; then
    echo "ERROR: bzImage fallback file not found: ${BZIMAGE_FILE}" >&2
    exit 1
fi

# 2. Build and Load Docker Image
if [[ ! -f "${DOCKER_TAR}" ]]; then
    echo "=== Building docker-image package ==="
    nix build .#docker-image -o "${DOCKER_TAR}"
fi

echo "=== Loading docker-image into podman ==="
gzip -dc "${DOCKER_TAR}" | podman load

# 3. Generate host-side baseline outputs
echo "=== Generating baseline host outputs via build.sh ==="
# Ensure initos.erofs is built
"${PROJECT_ROOT}/scripts/build.sh" build_initos
# Run build_qemu_test which creates target/disks/boot-initos-signed/
"${PROJECT_ROOT}/scripts/build.sh" build_qemu_test

# 4. Prepare container output dir
rm -rf "${DOCKER_OUT_DIR}"
mkdir -p "${DOCKER_OUT_DIR}"

# 5. Run signer container with podman
echo "=== Running initos-signer container via podman ==="
podman run --rm \
  -v "${KEYS_DIR}:/var/run/secrets/uefi-keys:ro" \
  -v "${BZIMAGE_FILE}:/bzImage:ro" \
  -v "${DOCKER_OUT_DIR}:/out" \
  -e KERNEL_BZIMAGE=/bzImage \
  localhost/initos-signer:latest \
  artifacts / /out

# 6. Verification and Comparison
echo "=== Comparing outputs between Host and Container ==="
PASS=0
FAIL=0

verify_exist() {
    if [[ -f "$1" ]]; then
        PASS=$((PASS + 1))
    else
        echo "  ❌ MISSING in container output: $1"
        FAIL=$((FAIL + 1))
    fi
}

compare_files() {
    local label="$1"
    local file1="$2"
    local file2="$3"
    
    if [[ ! -f "${file1}" ]]; then
        echo "  ❌ Host baseline signature missing: ${file1}"
        FAIL=$((FAIL + 1))
        return
    fi
    if [[ ! -f "${file2}" ]]; then
        echo "  ❌ Container signature missing: ${file2}"
        FAIL=$((FAIL + 1))
        return
    fi

    if cmp -s "${file1}" "${file2}"; then
        echo "  ✅ ${label} is identical to host baseline"
        PASS=$((PASS + 1))
    else
        echo "  ❌ ${label} differs from host baseline!"
        FAIL=$((FAIL + 1))
    fi
}

# Check existence of outputs
verify_exist "${DOCKER_OUT_DIR}/img/initos.erofs"
verify_exist "${DOCKER_OUT_DIR}/img/initos.erofs.sig"
verify_exist "${DOCKER_OUT_DIR}/img/boot-initos-signed.img"
verify_exist "${DOCKER_OUT_DIR}/boot/EFI/BOOT/BOOTX64.EFI"

# Extract KEY_ID
KEY_ID=$(openssl x509 -in "${KEYS_DIR}/db.crt" -pubkey -noout | \
         openssl rsa -pubin -outform DER 2>/dev/null | \
         openssl dgst -sha256 | sed 's/.*= //' | cut -c 1-16)

echo "  KEY_ID for db key is: ${KEY_ID}"

# Move container signatures to .container suffix to avoid conflict
mv "${DOCKER_OUT_DIR}/img/initos.erofs.sig" "${DOCKER_OUT_DIR}/img/initos.erofs.sig.container"
mv "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.sig" "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.sig.container"
mv "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.kernel.sig" "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.kernel.sig.container"
mv "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.initrd.sig" "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.initrd.sig.container"

# Generate host signatures for the exact same container files
echo "=== Generating host baseline signatures for container files ==="
export SECRETS="${KEYS_DIR}"
# Sign erofs
"${PROJECT_ROOT}/sidecar/bin/sign.sh" image "${DOCKER_OUT_DIR}/img" "initos.erofs"
# Sign config, kernel, initrd
openssl dgst -sha256 -sign "${KEYS_DIR}/db.key" -out "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.sig" "${DOCKER_OUT_DIR}/boot/EFI/BOOT/config"
openssl dgst -sha256 -sign "${KEYS_DIR}/db.key" -out "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.kernel.sig" "${DOCKER_OUT_DIR}/boot/EFI/BOOT/bzImage"
openssl dgst -sha256 -sign "${KEYS_DIR}/db.key" -out "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.initrd.sig" "${DOCKER_OUT_DIR}/boot/EFI/BOOT/initrd.img"

echo "=== Comparing signatures ==="
# Compare Ed25519 signature of erofs
compare_files "initos.erofs.sig" \
              "${DOCKER_OUT_DIR}/img/initos.erofs.sig" \
              "${DOCKER_OUT_DIR}/img/initos.erofs.sig.container"

# Compare config RSA signature
compare_files "config.sig" \
              "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.sig" \
              "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.sig.container"

# Compare kernel RSA signature
compare_files "bzImage.sig" \
              "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.kernel.sig" \
              "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.kernel.sig.container"

# Compare initrd RSA signature
compare_files "initrd.sig" \
              "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.initrd.sig" \
              "${DOCKER_OUT_DIR}/boot/EFI/BOOT/${KEY_ID}.initrd.sig.container"

# Verify container's BOOTX64.EFI signature against db.crt
echo "=== Verifying BOOTX64.EFI signature ==="
if command -v sbverify >/dev/null 2>&1; then
    if sbverify --cert "${KEYS_DIR}/db.crt" "${DOCKER_OUT_DIR}/boot/EFI/BOOT/BOOTX64.EFI" >/dev/null 2>&1; then
        echo "  ✅ BOOTX64.EFI Secure Boot signature verified successfully!"
        PASS=$((PASS + 1))
    else
        echo "  ❌ BOOTX64.EFI Secure Boot signature verification failed!"
        FAIL=$((FAIL + 1))
    fi
else
    # Fallback to manual check if sbverify is not installed on the host
    echo "  (sbverify not installed on host — skipping manual signature check)"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "🎉 SUCCESS: Docker image signing verified against host baseline! (${PASS} checks passed)"
else
    echo "❌ FAILURE: ${FAIL} checks failed (${PASS} passed)"
    exit 1
fi
