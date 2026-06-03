#!/usr/bin/env bash
#
# container_build.sh - container orchestration for initos builds.
# scripts/build.sh is intentionally container-agnostic and assumes the current
# environment already has the required tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

src=${src:-${PROJECT_ROOT}}
out=${out:-${src}/target}

cd "${src}"

PATH=${src}/prebuilt/bin:${src}/sidecar/bin:/sbin:/usr/sbin:$PATH

REPO=${REPO:-ghcr.io/costinm/initos}
TAG=${TAG:-latest}

mkdir -p "${out}/test/img"

cctl() {
    OUT_DIR="${out}/c/${POD:-initos_dev}" command cctl "$@"
}

build() {
    local pod="${POD:-initos_dev}"
    POD="${pod}" cctl "${src}/scripts/build.sh" "$@"
}

shell() {
    local pod="${POD:-initos_dev}"
    POD="${pod}" cctl "$@"
}

# Prepares the kernel dev container:
# - start with trixie
# - add deb packages required for building kernel
# Result is a reusable base image.
kernel_dev() {
    local pod=${1:-initos-dev}
    POD="${pod}" cctl start debian:trixie-slim
    POD="${pod}" cctl "${src}/sidecar/bin/setup-deb" kernel_build_tools
    podman commit "${pod}" "${pod}"
}

kernel() {
    POD=initos-kernel-dev cctl start initos-dev
    POD=initos-kernel-dev cctl "${src}/scripts/build.sh" kernel
}

firmware() {
    POD=initos-kernel-dev cctl start initos-dev
    POD=initos-kernel-dev cctl "${src}/scripts/build.sh" firmware
}

kernel_cloud() {
    POD=initos-kernel-cloud cctl start initos-dev
    POD=initos-kernel-cloud cctl "${src}/scripts/build.sh" kernel_cloud
}

# Build a clean Debian image using the setup-deb script, then package the
# running container rootfs as an erofs image.
_img() {
    local s=${1:?Usage: _img <setup-deb-target>}
    local d rootfs_img

    POD="${s}" cctl start debian:trixie-slim
    POD="${s}" cctl "${src}/sidecar/bin/setup-deb" "${s}"

    d=$(podman unshare podman mount "${s}")

    rm -rf "${out:?}/${s}"
    ln -s "${d}" "${out}/${s}"
    rootfs_img="${out}/test/img/${s}.erofs"

    podman unshare mkfs.erofs -zlz4hc "${rootfs_img}" "${d}"
}

hostui() {
    _img hostui
}

initos_dev() {
    _img initos_dev
    podman commit initos_dev initos_dev
}

initos_devui() {
    _img initos_devui
}

if [[ $# -gt 0 ]]; then
    "$@"
else
    build
fi
