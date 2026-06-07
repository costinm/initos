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
build_initos() {
    local initos_bin
    initos_bin=$(_resolve_initos_bin)
    local busybox
    busybox=$(_resolve_busybox)

    STAGING=${out}/staging/initos
    mkdir -p "${ARTIFACTS}/img"

    # Base rootfs and busybox in /opt/busybox
    if [ ! -f ${STAGING}/opt/busybox/bin/busybox ]; then
		mkdir -p "${STAGING}"/{dev,dev/shm,proc,sys,sysroot,home,mnt,media/cdrom,media/usb,run,etc,tmp,x,data,z,a,nix,src,initos,boot/efi,var/cache,var/log,opt/initos/bin,opt/busybox/bin,usr/bin,usr/sbin,usr/lib,usr/lib64}
		mkdir -p "${STAGING}"/usr/lib/modules "${STAGING}"/usr/lib/firmware

		cp "${busybox}" "${STAGING}/opt/busybox/bin/busybox"
		chmod 755 "${STAGING}/opt/busybox/bin/busybox"
		
		(
            cd ${STAGING}
            ln -s /usr/bin bin
            ln -s /usr/sbin sbin
            ln -s /usr/lib lib
            ln -s /usr/lib64 lib64
    		cd -
		)
		(
            cd ${STAGING}/opt/busybox/bin 
            for applet in $(${STAGING}/opt/busybox/bin/busybox --list); do
                ln -s /opt/busybox/bin/busybox "$applet"
            done
    		cd -
		)
	fi

	cp "${src}"/sidecar/bin/* "${STAGING}"/opt/initos/bin/
    chmod 755 "${STAGING}"/opt/initos/bin/*

	# Include unified initos binary
	cp "${initos_bin}" "${STAGING}/opt/initos/bin/initos"
	chmod 755 "${STAGING}/opt/initos/bin/initos"

    mkfs.erofs --all-root --force-uid=0 -T0 -zlz4 "${ARTIFACTS}/img/initos.erofs" "${STAGING}"

    echo "  Created: ${ARTIFACTS}/img/initos.erofs ($(du -h "${ARTIFACTS}/img/initos.erofs" | cut -f1))"
}

# 3. initrd.img - using initos binary and cpio
# Output: artifacts/boot/EFI/BOOT/initrd.img
build_initrd() {
    local initos_bin
    initos_bin=$(_resolve_initos_bin)

    local boot_path="${ARTIFACTS}/boot"
    mkdir -p "${boot_path}/EFI/BOOT"

    STAGING=${out}/staging/initrd
    mkdir -p $STAGING

	cp "${initos_bin}" "${STAGING}/init"
	chmod 755 "${STAGING}/init"

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

# Copy public UEFI keys that users enroll into PK/KEK/DB.
_copy_uefi_public_keys() {
    local boot_path="${1:?Usage: _copy_uefi_public_keys <boot_path>}"
    local keys_src="${src}/prebuilt/testdata/uefi-keys"
    local keys_dst="${boot_path}/keys"

    mkdir -p "${keys_dst}"
    for f in PK.crt PK.esl PK.auth KEK.crt KEK.esl KEK.auth db.crt db.esl db.auth; do
        cp "${keys_src}/${f}" "${keys_dst}/"
    done
    echo "  UEFI public keys → ${keys_dst}/"
}

# Build a FAT32 filesystem image from a boot directory.
# Uses mtools if available (no root needed), falls back to mkfs.vfat+loop mount.
_build_fat_image() {
    local boot_path="${1:?Usage: _build_fat_image <boot_path> <img_file>}"
    local img_file="${2:?Usage: _build_fat_image <boot_path> <img_file>}"

    # Calculate size: dir contents + 20% overhead, min 34MB (FAT32 needs ≥65525 clusters)
    local dir_size_kb img_size_mb
    dir_size_kb=$(du -sk "${boot_path}" | cut -f1)
    img_size_mb=$(( (dir_size_kb * 12 / 10 / 1024) + 1 ))
    [ "${img_size_mb}" -lt 64 ] && img_size_mb=64

    echo "  Building FAT image: ${img_file} (${img_size_mb}MB)"

    mkdir -p "$(dirname "${img_file}")"
    if command -v mformat >/dev/null 2>&1; then
        dd if=/dev/zero of="${img_file}" bs=1M count="${img_size_mb}" status=none
        mformat -i "${img_file}" -F -v "INITOSBOOT" ::
        (cd "${boot_path}" && mcopy -i "${img_file}" -s ./* ::)
    elif command -v mkfs.vfat >/dev/null 2>&1; then
        dd if=/dev/zero of="${img_file}" bs=1M count="${img_size_mb}" status=none
        mkfs.vfat -F 32 -n INITOSBOOT "${img_file}"
        local mnt
        mnt="$(mktemp -d)"
        su -c "mount -o loop ${img_file} ${mnt}"
        cp -a "${boot_path}/"* "${mnt}/"
        su -c "umount ${mnt}"
        rmdir "${mnt}"
    else
        echo "  WARNING: neither mtools nor dosfstools installed — skipping FAT image"
        return 0
    fi

    echo "  Created: ${img_file} ($(du -h "${img_file}" | cut -f1))"
}

# --- Boot functions are now in sidecar/bin/sign.sh ---

# 4. Build a test env for qemu validation.
build_qemu_test() {
    local keys="${src}/prebuilt/testdata/uefi-keys"

    [ -f "${ARTIFACTS}/img/initos.erofs" ] || {
        echo "Missing ${ARTIFACTS}/img/initos.erofs; run build_initos first" >&2
        return 1
    }

    # Build the three boot variants — sign.sh reads from artifacts/
    "${src}/sidecar/bin/sign.sh" build_boot_limine_unsigned "${ARTIFACTS}/boot" "${out}/disks"
    "${src}/sidecar/bin/sign.sh" build_boot_limine_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_initos_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}"

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

nix_all() {
    # initos, efi, kernel-cloud, kernel-host, firmware-erofs
    # 
    # initos-artifacts / -with-kernels
    # vm-cloud-profile - pulls initos, kernel-cloud, crosvm, etc.
    # docker-image / oci-cache-image
    
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
    build_rust
    build_initos
    build_boot
    build_bin
    "${src}/sidecar/bin/sign.sh" build_boot_limine_unsigned "${ARTIFACTS}/boot" "${out}/disks"
    "${src}/sidecar/bin/sign.sh" build_boot_limine_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_initos_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}"
    build_qemu_test
fi
