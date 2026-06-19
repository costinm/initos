#!/usr/bin/env bash
#
# test_sign_bwrap.sh — Test initos-signer in an isolated bubblewrap sandbox.
#
# Verifies that sign.sh can generate keys and sign artifacts without
# any host dependencies beyond what the Nix package provides.
#
# Usage:
#   nix build .#initos-signer -o result-signer
#   bash tests/test_sign_bwrap.sh [signer-path] [kernel-path]
#
# Or with kernel:
#   nix build ./linux -o result-kernel
#   bash tests/test_sign_bwrap.sh result-signer result-kernel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SIGNER="${1:-${PROJECT_ROOT}/result-signer}"
KERNEL_HOST="${2:-}"

if [[ ! -d "${SIGNER}" ]]; then
    echo "ERROR: signer path not found: ${SIGNER}" >&2
    echo "Build it first: nix build .#initos-signer -o result-signer" >&2
    exit 1
fi

if ! command -v bwrap >/dev/null 2>&1; then
    echo "ERROR: bubblewrap (bwrap) not found. Install it or use: nix-shell -p bubblewrap" >&2
    exit 1
fi

# Create a temp dir for writable output
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# Create minimal passwd and group files for the sandbox
echo "root:x:0:0:root:/root:/bin/sh" > "${WORK}/passwd"
echo "build:x:$(id -u):$(id -g):build:/out:/bin/sh" >> "${WORK}/passwd"
echo "root:x:0:" > "${WORK}/group"
echo "build:x:$(id -g):" >> "${WORK}/group"

echo "=== Testing initos-signer in bubblewrap sandbox ==="
echo "  Signer:    ${SIGNER}"
echo "  Kernel:    ${KERNEL_HOST:-<none>}"
echo "  Work dir:  ${WORK}"
echo ""

# Resolve the real signer path (may be a nix store symlink)
SIGNER_REAL="$(readlink -f "${SIGNER}")"

# Dynamically resolve bash and env from the signer script to be fully hermetic
BASH_PATH=$(head -n 1 "${SIGNER_REAL}/bin/sign.sh" | sed 's/^#!//' | awk '{print $1}')
COREUTILS_BIN=$(grep -o '/nix/store/[^:]*-coreutils-[^:]*/bin' "${SIGNER_REAL}/bin/sign.sh" | head -n 1)
ENV_PATH="${COREUTILS_BIN}/env"

echo "  Resolved bash: ${BASH_PATH}"
echo "  Resolved env:  ${ENV_PATH}"
echo ""

# Build the bwrap command with minimal mounts
BWRAP_ARGS=(
    # Minimal root
    --tmpfs /
    --proc /proc
    --dev /dev
    --tmpfs /tmp

    # Create empty dirs for symlinks and config files
    --dir /bin
    --dir /usr
    --dir /usr/bin
    --dir /etc

    # Symlink bash and env from the Nix store
    --symlink "${BASH_PATH}" /bin/sh
    --symlink "${BASH_PATH}" /bin/bash
    --symlink "${ENV_PATH}" /usr/bin/env

    # Bind-mount minimal user/group databases
    --ro-bind "${WORK}/passwd" /etc/passwd
    --ro-bind "${WORK}/group" /etc/group

    # Nix store (read-only) — needed for all deps
    --ro-bind /nix/store /nix/store

    # The signer package
    --ro-bind "${SIGNER_REAL}" "${SIGNER_REAL}"

    # Writable output dir
    --bind "${WORK}" /out

    # No network
    --unshare-net

    # No other namespaces that might leak host state
    --unshare-pid
    --die-with-parent
)

# Add kernel if provided, otherwise check host prebuilt fallback
KERNEL_TYPE=""
KERNEL_REAL=""

if [[ -n "${KERNEL_HOST}" ]]; then
    if [[ -d "${KERNEL_HOST}" ]]; then
        KERNEL_REAL="$(readlink -f "${KERNEL_HOST}")"
        KERNEL_TYPE="dir"
        BWRAP_ARGS+=(--ro-bind "${KERNEL_REAL}" /out/kernel)
    elif [[ -f "${KERNEL_HOST}" ]]; then
        KERNEL_REAL="$(readlink -f "${KERNEL_HOST}")"
        KERNEL_TYPE="file"
        BWRAP_ARGS+=(--ro-bind "${KERNEL_REAL}" /out/kernel/bzImage)
    fi
else
    # Fallback to typical build/output paths in the workspace
    if [[ -d "${PROJECT_ROOT}/result-kernel" ]]; then
        KERNEL_REAL="${PROJECT_ROOT}/result-kernel"
        KERNEL_TYPE="dir"
        BWRAP_ARGS+=(--ro-bind "${KERNEL_REAL}" /out/kernel)
        echo "  Using result-kernel fallback: ${KERNEL_REAL}"
    elif [[ -f "${PROJECT_ROOT}/target/img/bzImage" ]]; then
        KERNEL_REAL="${PROJECT_ROOT}/target/img/bzImage"
        KERNEL_TYPE="file"
        BWRAP_ARGS+=(--ro-bind "${KERNEL_REAL}" /out/kernel/bzImage)
        echo "  Using target/img/bzImage fallback: ${KERNEL_REAL}"
    elif [[ -f "${PROJECT_ROOT}/target/linux/arch/x86/boot/bzImage" ]]; then
        KERNEL_REAL="${PROJECT_ROOT}/target/linux/arch/x86/boot/bzImage"
        KERNEL_TYPE="file"
        BWRAP_ARGS+=(--ro-bind "${KERNEL_REAL}" /out/kernel/bzImage)
        echo "  Using target/linux/arch/x86/boot/bzImage fallback: ${KERNEL_REAL}"
    elif [[ -f "${PROJECT_ROOT}/target/linux/arch/x86_64/boot/bzImage" ]]; then
        KERNEL_REAL="${PROJECT_ROOT}/target/linux/arch/x86_64/boot/bzImage"
        KERNEL_TYPE="file"
        BWRAP_ARGS+=(--ro-bind "${KERNEL_REAL}" /out/kernel/bzImage)
        echo "  Using target/linux/arch/x86_64/boot/bzImage fallback: ${KERNEL_REAL}"
    else
        echo "WARNING: No kernel found in standard locations. Sandbox execution may fail." >&2
    fi
fi

# Run in sandbox
echo "--- Entering bubblewrap sandbox ---"
echo ""

bwrap "${BWRAP_ARGS[@]}" \
    --ro-bind "${PROJECT_ROOT}/tests/test_sign_sandbox_inner.sh" /out/test.sh \
    /bin/sh /out/test.sh "${SIGNER_REAL}" "${KERNEL_TYPE}" "${COREUTILS_BIN}"

echo ""
echo "--- Sandbox exited ---"
echo ""
echo "Signed outputs are in: ${WORK}/result/"
echo "Generated keys are in: ${WORK}/keys/"

# List the outputs
echo ""
echo "=== Output tree ==="
find "${WORK}/result" -type f 2>/dev/null | sort | sed "s|${WORK}/result/|  |"
