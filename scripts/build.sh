#!/usr/bin/env bash
#
# build.sh — Build the artifacts using build_NAME:
# - rust 'initos' binary
# - initrd.img - containing the binary
# - initos.erofs - containing the scripts, binary and busybox
# - kernel/modules for host and cloud

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

IMG_DIR=${IMG_DIR:-${out}/test/img}
mkdir -p "${out}/test" ${IMG_DIR}

BINARY="target/${MUSL_TARGET}/${PROFILE}/initos"

# 1. Rust binaries: EFI loader and the helper binary.
# May run directly in a dev container.
build_rust() {
    cargo build --release --target "${MUSL_TARGET}" --bin initos
    cargo build --release --target x86_64-unknown-uefi --bin efi
}


# 2. Build ${out}/disks/initos - containing the disk layout for the 
# basic read-only rootfs. Other variations based on containers are possible,
# just add the 2 /opt/{busybox,initos} directories and the skaffold dirs.
# 
# It includes: 
# - /opt/initos - the initos rust binary and scripts
# - /opt/busybox - a static busybox
# - other directories as empty mount points
# 
# It will than generate the erofs image, dm-verity and a file containing
# kernel command line options to load the image.
# Outputs:
# - disks/initos - expanded dir
# - ${IMG_DIR}/img/initos.erofs
build_initos() {
	STAGING=${out}/disks/initos
	IMG_DIR="${out}/disks/state/img"
    ROOTFS_IMG="${IMG_DIR}/initos.erofs"
    
    # Base rootfs and busybox in /opt/busybox
    # Only changes when busybox is updated, stable.
    if [ ! -f ${STAGING}/opt/busybox/bin/busybox ]; then
		mkdir -p "${STAGING}"/{dev,dev/shm,proc,sys,sysroot,home,mnt,media/cdrom,media/usb,run,etc,tmp,x,data,z,a,nix,src,initos,boot/efi,var/cache,var/log,opt/initos/bin,opt/busybox/bin,usr/bin,usr/sbin,usr/lib,usr/lib64}
		mkdir -p "${STAGING}"/usr/lib/modules "${STAGING}"/usr/lib/firmware

		BUSYBOX="${BUSYBOX:-${src}/prebuilt/bin/busybox}"
		cp "${BUSYBOX}" "${STAGING}/opt/busybox/bin/busybox"
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

	# Include unified initos binary (handles boot, TPM2, fscrypt, verify, mount)
	INITOS_BIN="${src}/target/x86_64-unknown-linux-musl/release/initos"
	cp "${INITOS_BIN}" "${STAGING}/opt/initos/bin/initos"
	chmod 755 "${STAGING}/opt/initos/bin/initos"

	mkdir -p "${IMG_DIR}"

    mkfs.erofs --all-root --force-uid=0 -T0 -zlz4 "${ROOTFS_IMG}" "${STAGING}"

    echo "  Created: ${ROOTFS_IMG} ($(du -h "${ROOTFS_IMG}" | cut -f1))"
}

# 3. initrd.img - using initos binary and cpio
# Artifact in ${out}/disks/boot
build_initrd() {
	STAGING=${out}/disks/initrd
    BOOT_PATH="${out}/disks/boot"
    mkdir -p ${BOOT_PATH}/EFI/BOOT
    
    mkdir -p $STAGING
	# Include unified initos binary (handles boot, TPM2, fscrypt, verify, mount)
	INITOS_BIN="${src}/target/x86_64-unknown-linux-musl/release/initos"
	cp "${INITOS_BIN}" "${STAGING}/init"
	chmod 755 "${STAGING}/init"

    (cd "${STAGING}" && find . | \
      sort | cpio --quiet --renumber-inodes -o -H newc | gzip \
        > ${out}/disks/boot/EFI/BOOT/initrd.img )
}

# 3.1 Build standard boot directory layout under disks/boot
build_boot() {
    build_initrd

    local boot_path="${out}/disks/boot"
    mkdir -p "${boot_path}/EFI/BOOT"

    # Copy Limine BOOTX64.EFI
    cp "${src}/prebuilt/boot/EFI/BOOT/BOOTX64.EFI" "${boot_path}/EFI/BOOT/"

    # Copy limine.conf
    cp "${src}/prebuilt/boot/EFI/BOOT/limine.conf" "${boot_path}/EFI/BOOT/"

    # Copy custom loader as initos.EFI
    local initos_efi_src="${out}/x86_64-unknown-uefi/release/efi.efi"
    if [ -f "${initos_efi_src}" ]; then
        cp "${initos_efi_src}" "${boot_path}/EFI/BOOT/initos.EFI"
    elif [ -f "${src}/target/x86_64-unknown-uefi/release/efi.efi" ]; then
        cp "${src}/target/x86_64-unknown-uefi/release/efi.efi" "${boot_path}/EFI/BOOT/initos.EFI"
    fi

    # Write default config file for initos.EFI
    cat > "${boot_path}/EFI/BOOT/config" <<EOF
INITOS_INIT=/opt/initos/bin/initos-init-dev console=tty1 loglevel=6 net.ifnames=0 panic=5
EOF
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
    local boot_path="${1:?Usage: _build_fat_image <boot_path> <img_name>}"
    local img_name="${2:?Usage: _build_fat_image <boot_path> <img_name>}"
    local img_file="${IMG_DIR}/${img_name}"

    # Calculate size: dir contents + 20% overhead, min 34MB (FAT32 needs ≥65525 clusters)
    local dir_size_kb img_size_mb
    dir_size_kb=$(du -sk "${boot_path}" | cut -f1)
    img_size_mb=$(( (dir_size_kb * 12 / 10 / 1024) + 1 ))
    [ "${img_size_mb}" -lt 64 ] && img_size_mb=64

    echo "  Building FAT image: ${img_file} (${img_size_mb}MB)"

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
# This calls step 3 to rebuild the initrd.
build_qemu_test() {
    local genimage_dir="${out}/test"
    local rootfs_img="${out}/disks/state/img/initos.erofs"
    local keys="${src}/prebuilt/testdata/uefi-keys"

    [ -f "${rootfs_img}" ] || {
        echo "Missing ${rootfs_img}; run build_initos first" >&2
        return 1
    }

    # Build the three boot variants under disks/
    "${src}/sidecar/bin/sign.sh" build_boot_limine_unsigned "${out}/disks" "${out}/disks"
    "${src}/sidecar/bin/sign.sh" build_boot_limine_signed "${out}/disks/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_initos_signed "${out}/disks/boot" "${out}/disks" "${keys}"

    build_qemu_state
}

# 4.1 Pack a STATE rootfs - using img/ dir.
# Used to verify initrd can find the STATE (even as a separate disk),
# and to build a GPT disk for PARTLABEL verification.
build_qemu_state() {
    local rootfs_img="${out}/disks/state/img/initos.erofs"
    local genimage_dir="${out}/test"
    local data_img="state.ext4"
    local img_size_bytes img_size_mb state_size_mb

    img_size_bytes=$(stat -c%s "${rootfs_img}")
    img_size_mb=$(( (img_size_bytes + 1048575) / 1048576 ))
    state_size_mb=$(( img_size_mb + 32 + 64 ))
    echo "STATE_SIZE_MB: ${state_size_mb} (IMG: ${rootfs_img})"

    mkdir -p "${genimage_dir}"
    dd if=/dev/zero of="${genimage_dir}/${data_img}" bs=1M count="${state_size_mb}" status=none

    mkfs.ext4 -q -F -b 4096 \
        -O inline_data,extents,uninit_bg,dir_index,has_journal,verity,encrypt \
        -L "STATE" -d "${out}/disks/state" \
        "${genimage_dir}/${data_img}"
}

# 4.2 (optional) Build the GPT disk.
build_qemu_gpt() {
    local genimage_dir="${out}/test"

    PATH="/usr/sbin:/sbin:${PATH}"
    mkdir -p "${genimage_dir}/tmp"

    cat > "${genimage_dir}/config.ini" <<EOF
image disk.img {
    hdimage { partition-table-type = "gpt" }
    partition INITOS {
        image = "${out}/disks/state/img/initos.erofs"
    }
}
EOF

    echo "Running genimage..."
    (
        cd "${genimage_dir}"
        genimage --config config.ini \
            --rootpath "${out}/disks" --tmppath tmp \
            --outputpath "${out}/test" \
            --inputpath "${genimage_dir}"
    )

    echo "  Disk image:       ${out}/test/disk.img"
}

sign_qemu_efi() {
    local esp_dir="${out}/test_efi"
    local keys="${src}/prebuilt/testdata/uefi-keys"
    local boot="${esp_dir}/EFI/BOOT"

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

    # nix build .#initos -o target/result-initos
    # nix build .#efi -o target/result-efi
    

    # --no-link --print-out-paths
}

test() {
    echo "=== Building artifacts ==="
    build_rust
    build_initos
    build_boot
    build_qemu_test

    echo "=== Running Cargo Tests ==="
    INITOS_BINARY="${out}/${MUSL_TARGET}/${PROFILE}/initos" cargo test --workspace -- --include-ignored

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
    "${src}/sidecar/bin/sign.sh" build_boot_limine_unsigned "${out}/disks" "${out}/disks"
    "${src}/sidecar/bin/sign.sh" build_boot_limine_signed "${out}/disks/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_initos_signed "${out}/disks/boot" "${out}/disks" "${keys}"
    build_qemu_test
fi
