#!/usr/bin/env bash
#
# build.sh — Build the artifacts using build_NAME:
# - rust 'initos' binary
# - initrd.img - containing the binary
# - initos.erofs - containing the scripts, binary and busybox
# - kernel/modules for host and cloud
#
# Output layout (under $out/artifacts/):
#   boot/EFI/BOOT/  — initrd.img, BOOTX64.EFI, initos.EFI, limine.conf
#   img/            — initos.erofs
#   bin/            — initos binary, sidecar scripts
#
# Environment variables for Nix integration:
#   INITOS_BIN    — path to pre-built initos binary
#   EFI_BIN       — path to pre-built efi.efi binary
#   USE_BUSYBOX   — path to static busybox binary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

src=${src:-${PROJECT_ROOT}}
if [[ ! "$src" =~ ^/ ]]; then
    src="$(pwd)/$src"
fi
out=${out:-${src}/target}
if [[ ! "$out" =~ ^/ ]]; then
    out="$(pwd)/$out"
fi

PROFILE="release"
MUSL_TARGET="x86_64-unknown-linux-musl"
PREBUILT_BIN="${PROJECT_ROOT}/prebuilt/bin"
PREBUILT_BOOT="${PROJECT_ROOT}/prebuilt/boot"
TMPDIR="${TMPDIR:-/tmp}"

cd "${src}"
export src out

PATH=${src}/prebuilt/bin:${src}/sidecar/bin:/sbin:/usr/sbin:$PATH

ARTIFACTS="${out}/artifacts"

# Resolve initos binary: env var > cargo target
_resolve_initos_bin() {
    if [ -n "${INITOS_BIN:-}" ] && [ -f "${INITOS_BIN}" ]; then
        echo "${INITOS_BIN}"
    elif [ -f "${src}/target/${MUSL_TARGET}/${PROFILE}/initos" ]; then
        echo "${src}/target/${MUSL_TARGET}/${PROFILE}/initos"
    else
        echo "ERROR: initos binary not found. Set INITOS_BIN or run build_rust first." >&2
        return 1
    fi
}

# Resolve EFI binary: env var > cargo target
_resolve_efi_bin() {
    if [ -n "${EFI_BIN:-}" ] && [ -f "${EFI_BIN}" ]; then
        echo "${EFI_BIN}"
    elif [ -f "${src}/target/x86_64-unknown-uefi/${PROFILE}/efi.efi" ]; then
        echo "${src}/target/x86_64-unknown-uefi/${PROFILE}/efi.efi"
    else
        echo "ERROR: efi.efi binary not found. Set EFI_BIN or run build_rust first." >&2
        return 1
    fi
}

# Resolve busybox: env var > prebuilt > system
_resolve_busybox() {
    if [ -n "${USE_BUSYBOX:-}" ] && [ -f "${USE_BUSYBOX}" ]; then
        echo "${USE_BUSYBOX}"
    elif [ -f "${PREBUILT_BIN}/busybox" ]; then
        echo "${PREBUILT_BIN}/busybox"
    elif command -v busybox >/dev/null 2>&1; then
        command -v busybox
    else
        echo "ERROR: busybox not found. Set USE_BUSYBOX." >&2
        return 1
    fi
}

# 1. Rust binaries: EFI loader and the helper binary.
# May run directly in a dev container.
build_rust() {
    cargo build --release --target "${MUSL_TARGET}" --bin initos
    cargo build --release --target x86_64-unknown-uefi --bin efi
}


# 2. Build the read-only rootfs erofs image.
# Outputs: artifacts/img/initos.erofs
# Populate a staging directory with the initos layout (busybox, sidecar scripts, initos binary).
_populate_staging() {
    local staging_dir="${1:?Usage: _populate_staging <staging_dir>}"
    local initos_bin
    initos_bin=$(_resolve_initos_bin)
    local busybox
    busybox=$(_resolve_busybox)

    # Base rootfs and busybox in /opt/busybox
    if [ ! -f "${staging_dir}/opt/busybox/bin/busybox" ]; then
        mkdir -p "${staging_dir}"/{dev,dev/shm,proc,sys,sysroot,home,mnt,media/cdrom,media/usb,run,etc,tmp,x,data,z,a,nix,src,initos,boot/efi,var/cache,var/log,opt/initos/bin,opt/busybox/bin,usr/bin,usr/sbin,usr/lib,usr/lib64}
        mkdir -p "${staging_dir}"/usr/lib/modules "${staging_dir}"/usr/lib/firmware

        cp "${busybox}" "${staging_dir}/opt/busybox/bin/busybox"
        chmod 755 "${staging_dir}/opt/busybox/bin/busybox"

        (
            cd "${staging_dir}"
            ln -sf /usr/bin bin
            ln -sf /usr/sbin sbin
            ln -sf /usr/lib lib
            ln -sf /usr/lib64 lib64
        )
        (
            cd "${staging_dir}/opt/busybox/bin"
            for applet in $(./busybox --list); do
                ln -sf /opt/busybox/bin/busybox "$applet"
            done
        )
    fi

    cp "${src}"/sidecar/bin/* "${staging_dir}"/opt/initos/bin/
    chmod 755 "${staging_dir}"/opt/initos/bin/*

    # Include unified initos binary
    cp "${initos_bin}" "${staging_dir}/opt/initos/bin/initos"
    chmod 755 "${staging_dir}/opt/initos/bin/initos"
}

# 2. Build the read-only rootfs erofs image.
# Outputs: artifacts/img/initos.erofs
build_initos() {
    STAGING=${out}/staging/initos
    mkdir -p "${ARTIFACTS}/img"

    _populate_staging "${STAGING}"

    mkfs.erofs --all-root --force-uid=0 -T0 -zlz4 "${ARTIFACTS}/img/initos.erofs" "${STAGING}"

    echo "  Created: ${ARTIFACTS}/img/initos.erofs ($(du -h "${ARTIFACTS}/img/initos.erofs" | cut -f1))"
}

# 3. initrd.img - using initos layout and cpio
# Output: artifacts/boot/EFI/BOOT/initrd.img
build_initrd() {
    local boot_path="${ARTIFACTS}/boot"
    mkdir -p "${boot_path}/EFI/BOOT"

    STAGING=${out}/staging/initrd
    # Always clean and rebuild staging for initrd to avoid stale files
    rm -rf "${STAGING}"
    _populate_staging "${STAGING}"

    # Link /opt/initos/bin/initos to /init in initrd
    ln -sf /opt/initos/bin/initos "${STAGING}/init"

    (cd "${STAGING}" && find . | \
      sort | cpio --quiet --renumber-inodes -o -H newc | gzip \
        > "${boot_path}/EFI/BOOT/initrd.img" )
}

# 3.1 Build standard boot directory layout under artifacts/boot
build_boot() {
    build_initrd

    local boot_path="${ARTIFACTS}/boot"
    mkdir -p "${boot_path}/EFI/BOOT"

    # Copy Limine BOOTX64.EFI
    cp "${src}/prebuilt/boot/EFI/BOOT/BOOTX64.EFI" "${boot_path}/EFI/BOOT/"

    # Copy limine.conf
    cp "${src}/prebuilt/boot/EFI/BOOT/limine.conf" "${boot_path}/EFI/BOOT/"

    # Copy custom loader as initos.EFI
    local efi_bin
    efi_bin=$(_resolve_efi_bin)
    cp "${efi_bin}" "${boot_path}/EFI/BOOT/initos.EFI"
}

# 3.2 Copy sidecar scripts and initos binary to artifacts/bin
build_bin() {
    local initos_bin
    initos_bin=$(_resolve_initos_bin)

    mkdir -p "${ARTIFACTS}/bin"
    cp "${src}"/sidecar/bin/* "${ARTIFACTS}/bin/"
    cp "${initos_bin}" "${ARTIFACTS}/bin/initos"
    chmod 755 "${ARTIFACTS}/bin/"*
}

# --- Boot functions are now in sidecar/bin/sign.sh ---

_read_image_pub_key() {
    local keys="${1:?Usage: _read_image_pub_key <keys_dir>}"
    local pub_key_file="${keys}/image_key.pub.b64"

    if [ ! -s "${pub_key_file}" ]; then
        echo "ERROR: ${pub_key_file} is not present or empty (required for INITOS_PUB_KEY)" >&2
        return 1
    fi

    tr -d '\r\n' < "${pub_key_file}"
}

# 4. Build a test env for qemu validation.
build_qemu_test() {
    local keys="${src}/prebuilt/testdata/uefi-keys"
    local pub_key
    pub_key=$(_read_image_pub_key "${keys}")

    [ -f "${ARTIFACTS}/img/initos.erofs" ] || {
        echo "Missing ${ARTIFACTS}/img/initos.erofs; run build_initos first" >&2
        return 1
    }

    # Build the three boot variants — sign.sh reads from artifacts/
    "${src}/sidecar/bin/sign.sh" build_boot_limine_unsigned "${ARTIFACTS}/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_limine_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}" "${pub_key}"
    "${src}/sidecar/bin/sign.sh" build_boot_initos_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}" "${pub_key}"

    build_qemu_state
}

# 4.1 Pack a STATE rootfs containing all image artifacts.
# Creates target/qemu/state.ext4 with an img/ subdir.
build_qemu_state() {
    local rootfs_img="${ARTIFACTS}/img/initos.erofs"
    local qemu_dir="${out}/qemu"
    local state_staging="${out}/staging/state"
    local data_img="state.ext4"
    local img_size_bytes img_size_mb state_size_mb

    # Stage img/ contents for the STATE partition
    rm -rf "${state_staging}"
    mkdir -p "${state_staging}/img"
    cp "${rootfs_img}" "${state_staging}/img/initos.erofs"

    # Also copy signed artifacts if they exist (modules, firmware, sigs)
    for f in "${ARTIFACTS}"/img/modules-*.erofs "${ARTIFACTS}"/img/firmware.erofs \
             "${ARTIFACTS}"/img/*.sig; do
        [ -f "$f" ] && cp "$f" "${state_staging}/img/"
    done

    img_size_bytes=$(du -sb "${state_staging}" | cut -f1)
    img_size_mb=$(( (img_size_bytes + 1048575) / 1048576 ))
    state_size_mb=$(( img_size_mb + 32 + 64 ))
    echo "STATE_SIZE_MB: ${state_size_mb} (staging: ${state_staging})"

    mkdir -p "${qemu_dir}"
    dd if=/dev/zero of="${qemu_dir}/${data_img}" bs=1M count="${state_size_mb}" status=none

    mkfs.ext4 -q -F -b 4096 \
        -O inline_data,extents,uninit_bg,dir_index,has_journal,verity,encrypt \
        -L "STATE" -d "${state_staging}" \
        "${qemu_dir}/${data_img}"
}

# 4.2 (optional) Build the GPT disk.
build_qemu_gpt() {
    local genimage_dir="${out}/qemu"

    PATH="/usr/sbin:/sbin:${PATH}"
    mkdir -p "${genimage_dir}/tmp"

    cat > "${genimage_dir}/config.ini" <<EOF
image disk.img {
    hdimage { partition-table-type = "gpt" }
    partition INITOS {
        image = "${ARTIFACTS}/img/initos.erofs"
    }
}
EOF

    echo "Running genimage..."
    (
        cd "${genimage_dir}"
        genimage --config config.ini \
            --rootpath "${out}" --tmppath tmp \
            --outputpath "${genimage_dir}" \
            --inputpath "${genimage_dir}"
    )

    echo "  Disk image:       ${genimage_dir}/disk.img"
}

sign_qemu_efi() {
    local esp_dir="${out}/test_efi"
    local keys="${src}/prebuilt/testdata/uefi-keys"

    "${src}/sidecar/bin/sign.sh" efi "${keys}" "${esp_dir}/"
}

install_limine_cli() {
   
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

### Kernel and firmware targets.
# These run in the current environment. Use scripts/container_build.sh for
# container orchestration.
kernel() {
    "${src}/scripts/setup-kernel" kernel
}

nvidia() {
    "${src}/scripts/setup-kernel" nvidia
}

firmware() {
    "${src}/scripts/setup-kernel" add_firmware
}

align_flake_locks() {
    nix flake lock ./linux --reference-lock-file flake.lock
}

nix_all() {
    # initos, efi, kernel-cloud, kernel-host, firmware-erofs
    # 
    # initos-artifacts / -with-kernels
    # vm-cloud-profile - pulls initos, kernel-cloud, crosvm, etc.
    # docker-image
    
    nix build ./linux -o target/result-kernel-host
    nix build  -o target/result


    nix build .#docker-image

    # nix build .#initos -o target/result-initos
    # nix build .#efi -o target/result-efi
    

    # --no-link --print-out-paths
}

test() {
    echo "=== Building artifacts ==="
    build_rust
    build_initos
    build_boot
    build_bin
    build_qemu_test

    echo "=== Running Cargo Tests ==="
    INITOS_BINARY="$(_resolve_initos_bin)" cargo test --workspace -- --include-ignored

    echo "=== Running Age Encrypt/Decrypt Script Test ==="
    "${src}/tests/test_encrypt_decrypt.sh"

    echo "=== Running QEMU Integration Test ==="
    "${src}/tests/run_qemu.sh"

    echo "✅ ALL TESTS PASSED!"
}

if [[ $# -gt 0 ]]; then
    "$@"
else
    keys="${src}/prebuilt/testdata/uefi-keys"
    pub_key=$(_read_image_pub_key "${keys}")
    build_rust
    build_initos
    build_boot
    build_bin
    "${src}/sidecar/bin/sign.sh" build_boot_limine_unsigned "${ARTIFACTS}/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_limine_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}" "${pub_key}"
    "${src}/sidecar/bin/sign.sh" build_boot_initos_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}" "${pub_key}"
    build_qemu_test
fi
