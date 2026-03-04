#!/usr/bin/env bash
#
# build.sh — Build the initos Rust binary.
#
# Usage: ./scripts/build.sh
#
# By default builds a static musl binary (x86_64-unknown-linux-musl)
# in release mode. 
#
# Output: prints the path to the built binary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE="release"
MUSL_TARGET="x86_64-unknown-linux-musl"

cd "${PROJECT_ROOT}"

out=${out:-${PROJECT_ROOT}/target}
mkdir -p "${out}/test"

cargo build --release --target "${MUSL_TARGET}"
BINARY="target/${MUSL_TARGET}/${PROFILE}/initos"

if [[ -f "${BINARY}" ]]; then
    echo "=== Build complete ==="
    echo "  Binary: ${PROJECT_ROOT}/${BINARY}"
    echo "  Size:   $(du -h "${BINARY}" | cut -f1)"
else
    echo "ERROR: binary not found at ${BINARY}"
    exit 1
fi


INITRD_STAGING=$(mktemp -d /tmp/initos-initrd.XXXXX)
trap 'rm -rf "${INITRD_STAGING:-}"' EXIT

mkdir -p "${INITRD_STAGING}"/{dev,proc,sys,mnt/data,mnt/root}
cp "${BINARY}" "${INITRD_STAGING}/init"
chmod 755 "${INITRD_STAGING}/init"

INITRD_IMG="${out}/test/initrd.img"
(cd "${INITRD_STAGING}" && find . | sort | cpio --quiet -o -H newc | gzip) >"${INITRD_IMG}"
echo "  Created: ${INITRD_IMG} ($(ls -lh "${INITRD_IMG}" | awk '{print $5}') )"

echo "Copying initrd to prebuilt..."
mkdir -p "${PROJECT_ROOT}/prebuilt/boot/EFI/LINUX"
cp "${INITRD_IMG}" "${PROJECT_ROOT}/prebuilt/boot/EFI/LINUX/initrd.img"
