#!/usr/bin/env bash
#
# setup-deps.sh — Download/build external dependencies into prebuilt/.
#
# All tools are placed in prebuilt/bin/ (added to PATH by build.sh).
# No root required — uses dpkg-deb extraction and source builds.
#
# Usage:
#   setup-deps.sh              Install all deps (skip if already present)
#   setup-deps.sh --force      Rebuild/re-download everything
#   setup-deps.sh <component>  Install a single component:
#     mtools      - mformat, mcopy, mdir, mattrib (from Debian .deb)
#     bwrap       - bubblewrap (from Debian .deb)
#     limine-cli  - limine enroll-config CLI tool (from source)
#     limine-efi  - limine bootloader EFI binaries (from release)
#     all          - everything (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREBUILT_BIN="${PROJECT_ROOT}/prebuilt/bin"
PREBUILT_BOOT="${PROJECT_ROOT}/prebuilt/boot"
TMPDIR="${TMPDIR:-/tmp}"

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
    shift
fi

COMPONENT="${1:-all}"

mkdir -p "${PREBUILT_BIN}"
mkdir -p "${PREBUILT_BOOT}/EFI/BOOT"

need_install() {
    local bin="$1"
    if $FORCE; then return 0; fi
    if [ -x "${PREBUILT_BIN}/${bin}" ]; then
        echo "  [SKIP] ${bin} already installed (use --force to rebuild)"
        return 1
    fi
    return 0
}

# ── mtools ────────────────────────────────────────────────────────────

install_mtools() {
    local bins=(mformat mcopy mdir mattrib)
    local all_ok=true
    for b in "${bins[@]}"; do
        need_install "$b" || all_ok=false
    done
    $all_ok || return 0

    echo "=== Installing mtools (mformat, mcopy, mdir, mattrib) ==="
    local work="${TMPDIR}/initos-deps-mtools"
    rm -rf "${work}"
    mkdir -p "${work}"

    cd "${work}"
    apt-get download mtools
    dpkg-deb -x mtools_*.deb extracted

    for b in "${bins[@]}"; do
        cp "extracted/usr/bin/${b}" "${PREBUILT_BIN}/"
        chmod 755 "${PREBUILT_BIN}/${b}"
        echo "  Installed: ${b}"
    done

    rm -rf "${work}"
    echo "  Done."
}

# ── bubblewrap ────────────────────────────────────────────────────────

install_bwrap() {
    need_install bwrap || return 0

    echo "=== Installing bubblewrap ==="
    local work="${TMPDIR}/initos-deps-bwrap"
    rm -rf "${work}"
    mkdir -p "${work}"

    cd "${work}"
    apt-get download bubblewrap
    dpkg-deb -x bubblewrap_*.deb extracted

    cp "extracted/usr/bin/bwrap" "${PREBUILT_BIN}/"
    chmod 755 "${PREBUILT_BIN}/bwrap"
    echo "  Installed: bwrap"

    rm -rf "${work}"
    echo "  Done."
}

# ── limine CLI tool (enroll-config, bios-install, etc.) ──────────────

install_limine_cli() {
    need_install limine || return 0

    echo "=== Building limine CLI tool ==="

    local limine_ver="12.3.1"
    local work="${TMPDIR}/initos-deps-limine"
    rm -rf "${work}"
    mkdir -p "${work}"

    cd "${work}"
    echo "  Downloading limine ${limine_ver}..."
    curl -sLO "https://github.com/limine-bootloader/limine/releases/download/v${limine_ver}/limine-${limine_ver}.tar.xz"
    tar xf "limine-${limine_ver}.tar.xz"

    cd "limine-${limine_ver}"
    echo "  Configuring..."
    OBJCOPY_FOR_TARGET=objcopy \
    OBJDUMP_FOR_TARGET=objdump \
    READELF_FOR_TARGET=readelf \
        ./configure --prefix="${work}/install" \
            CC_FOR_TARGET=gcc LD_FOR_TARGET=ld \
            > /dev/null 2>&1

    echo "  Building..."
    make -j"$(nproc)" > /dev/null 2>&1

    cp "bin/limine" "${PREBUILT_BIN}/"
    chmod 755 "${PREBUILT_BIN}/limine"
    echo "  Installed: limine ($("${PREBUILT_BIN}/limine" --version 2>&1 | head -1))"

    rm -rf "${work}"
    echo "  Done."
}

# ── limine bootloader EFI binaries ────────────────────────────────────

install_limine_efi() {
    local efi_file="${PREBUILT_BOOT}/EFI/BOOT/BOOTX64.EFI"
    if ! $FORCE && [ -f "${efi_file}" ]; then
        echo "  [SKIP] limine EFI already installed (use --force to re-download)"
        return 0
    fi

    echo "=== Downloading limine bootloader EFI binaries ==="

    local limine_ver="12.3.1"
    local work="${TMPDIR}/initos-deps-limine-efi"
    rm -rf "${work}"
    mkdir -p "${work}"

    cd "${work}"
    curl -sLO "https://github.com/limine-bootloader/limine/releases/download/v${limine_ver}/limine-binary.tar.xz"
    tar xf limine-binary.tar.xz

    # Only copy the x86_64 EFI binary (we use UEFI boot).
    cp limine-binary/BOOTX64.EFI "${PREBUILT_BOOT}/EFI/BOOT/BOOTX64.EFI"
    chmod 644 "${PREBUILT_BOOT}/EFI/BOOT/BOOTX64.EFI"
    echo "  Installed: limine BOOTX64.EFI (v${limine_ver})"

    # Also keep a copy of limine.c for reference.
    cp limine-binary/limine.c "${PREBUILT_BOOT}/EFI/BOOT/limine.h"

    rm -rf "${work}"
    echo "  Done."
}

# ── All ───────────────────────────────────────────────────────────────

install_all() {
    install_mtools
    install_bwrap
    install_limine_cli
    install_limine_efi
    echo ""
    echo "=== All dependencies installed to prebuilt/ ==="
    echo ""
    ls -la "${PREBUILT_BIN}/"
}

# ── Dispatch ──────────────────────────────────────────────────────────

case "${COMPONENT}" in
    mtools)       install_mtools ;;
    bwrap)        install_bwrap ;;
    limine-cli)   install_limine_cli ;;
    limine-efi)   install_limine_efi ;;
    all)          install_all ;;
    *)
        echo "Unknown component: ${COMPONENT}"
        echo "Usage: $0 [--force] [all|mtools|bwrap|limine-cli|limine-efi]"
        exit 1
        ;;
esac
