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
#   LIMINE_EFI    — path to Limine BOOTX64.EFI
#   KERNEL_BZIMAGE — path to a kernel bzImage
#   KERNEL_DIR     — directory containing bzImage

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

# Resolve busybox: env var > system
_resolve_busybox() {
    if [ -n "${USE_BUSYBOX:-}" ] && [ -f "${USE_BUSYBOX}" ]; then
        echo "${USE_BUSYBOX}"
    elif command -v busybox >/dev/null 2>&1; then
        command -v busybox
    else
        echo "ERROR: busybox not found. Set USE_BUSYBOX." >&2
        return 1
    fi
}

# Resolve Limine EFI binary: env var > limine package next to CLI
_resolve_limine_efi() {
    if [ -n "${LIMINE_EFI:-}" ] && [ -f "${LIMINE_EFI}" ]; then
        echo "${LIMINE_EFI}"
        return 0
    fi

    if command -v limine >/dev/null 2>&1; then
        local limine_bin limine_root limine_efi
        limine_bin="$(command -v limine)"
        limine_root="$(cd "$(dirname "${limine_bin}")/.." && pwd)"
        limine_efi="${limine_root}/share/limine/BOOTX64.EFI"
        if [ -f "${limine_efi}" ]; then
            echo "${limine_efi}"
            return 0
        fi
    fi

    echo "ERROR: Limine BOOTX64.EFI not found. Set LIMINE_EFI." >&2
    return 1
}

_resolve_kernel_bzimage() {
    if [ -n "${KERNEL_BZIMAGE:-}" ] && [ -f "${KERNEL_BZIMAGE}" ]; then
        echo "${KERNEL_BZIMAGE}"
        return 0
    fi

    if [ -n "${KERNEL_DIR:-}" ] && [ -f "${KERNEL_DIR}/bzImage" ]; then
        echo "${KERNEL_DIR}/bzImage"
        return 0
    fi

    local candidate
    for candidate in \
        "${out}/opt/kernel-image/bzImage" \
        "${out}/img/bzImage" \
        "${out}/linux/arch/x86/boot/bzImage" \
        "${out}/linux/arch/x86_64/boot/bzImage" \
        "${src}/target/nix/profiles/opt/kernel-image/bzImage" \
        "${src}/result-kernel/opt/kernel-image/bzImage" \
        "${src}/result-kernel/bzImage"; do
        if [ -f "${candidate}" ]; then
            echo "${candidate}"
            return 0
        fi
    done

    echo "ERROR: kernel bzImage not found. Run './scripts/build.sh kernel' first, or set KERNEL_BZIMAGE/KERNEL_DIR." >&2
    return 1
}

_resolve_kernel_dir() {
    if [ -n "${KERNEL_DIR:-}" ] && [ -f "${KERNEL_DIR}/bzImage" ]; then
        echo "${KERNEL_DIR}"
        return 0
    fi

    if [ -n "${KERNEL_BZIMAGE:-}" ] && [ -f "${KERNEL_BZIMAGE}" ]; then
        dirname "${KERNEL_BZIMAGE}"
        return 0
    fi

    local candidate
    for candidate in \
        "${out}/opt/kernel-image" \
        "${src}/target/nix/profiles/opt/kernel-image" \
        "${src}/result-kernel/opt/kernel-image" \
        "${src}/result-kernel"; do
        if [ -f "${candidate}/bzImage" ]; then
            echo "${candidate}"
            return 0
        fi
    done

    return 1
}

_resolve_qemu_kernel_release() {
    if [ -n "${INITOS_QEMU_KERNEL_RELEASE:-}" ]; then
        echo "${INITOS_QEMU_KERNEL_RELEASE}"
        return 0
    fi

    local kernel_dir
    if kernel_dir=$(_resolve_kernel_dir); then
        local module_dir
        for module_dir in "${kernel_dir}"/modules-*; do
            if [ -d "${module_dir}" ]; then
                basename "${module_dir}" | sed 's/^modules-//'
                return 0
            fi
        done
    fi

    echo "6.18.34"
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
    if [ ! -f "${staging_dir}/opt/busybox/bin/busybox" ] || [ -L "${staging_dir}/opt/busybox/bin/busybox" ]; then
        mkdir -p "${staging_dir}"/{dev,dev/shm,proc,sys,sysroot,home,mnt,media/cdrom,media/usb,run,etc,tmp,x,data,z,a,nix,src,initos,boot/efi,var/cache,var/log,opt/initos/bin,opt/busybox/bin,usr/bin,usr/sbin,usr/lib,usr/lib64}
        mkdir -p "${staging_dir}"/usr/lib/modules "${staging_dir}"/usr/lib/firmware

        rm -f "${staging_dir}/opt/busybox/bin/busybox"
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
                [ "${applet}" = busybox ] && continue
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

build_qemu_initos() {
    STAGING=${out}/staging/initos-qemu
    mkdir -p "${ARTIFACTS}/img"
    rm -rf "${STAGING}"

    _populate_staging "${STAGING}"
    cp "${STAGING}/opt/initos/bin/initos-init" "${STAGING}/opt/initos/bin/initos-init-base"
    cp "${src}/sidecar/bin/initos-init-qemu" "${STAGING}/opt/initos/bin/initos-init"
    chmod 755 "${STAGING}/opt/initos/bin/initos-init"
    chmod 755 "${STAGING}/opt/initos/bin/initos-init-base"

    mkfs.erofs --all-root --force-uid=0 -T0 -zlz4 "${ARTIFACTS}/img/initos.erofs" "${STAGING}"

    echo "  Created QEMU test rootfs: ${ARTIFACTS}/img/initos.erofs ($(du -h "${ARTIFACTS}/img/initos.erofs" | cut -f1))"
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
    local limine_efi
    limine_efi=$(_resolve_limine_efi)
    cp "${limine_efi}" "${boot_path}/EFI/BOOT/BOOTX64.EFI"

    # Copy limine.conf
    cp "${src}/prebuilt/boot/EFI/BOOT/limine.conf" "${boot_path}/EFI/BOOT/"

    # Copy custom loader as initos.EFI
    local efi_bin
    efi_bin=$(_resolve_efi_bin)
    cp "${efi_bin}" "${boot_path}/EFI/BOOT/initos.EFI"

    local kernel_bzimage
    kernel_bzimage=$(_resolve_kernel_bzimage)
    cp "${kernel_bzimage}" "${boot_path}/EFI/BOOT/bzImage"
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

# 4. Build a test env for qemu validation.
build_qemu_test() {
    local keys="${src}/prebuilt/testdata/uefi-keys"

    build_qemu_initos

    SECRETS="${keys}" "${src}/sidecar/bin/sign.sh" image "${ARTIFACTS}/img" "initos.erofs"
    build_qemu_mount_fixtures "${keys}"

    # Build the three boot variants — sign.sh reads from artifacts/
    "${src}/sidecar/bin/sign.sh" build_boot_limine_unsigned "${ARTIFACTS}/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_limine_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}"
    "${src}/sidecar/bin/sign.sh" build_boot_initos_signed "${ARTIFACTS}/boot" "${out}/disks" "${keys}"

    build_qemu_state
}

build_qemu_mount_fixtures() {
    local keys="${1:?Usage: build_qemu_mount_fixtures <keys-dir>}"
    local fixture_root="${out}/staging/qemu-mount-fixtures"
    local kernel_release
    kernel_release=$(_resolve_qemu_kernel_release)

    mkdir -p "${ARTIFACTS}/img"
    rm -rf "${fixture_root}"

    mkdir -p "${fixture_root}/firmware/test"
    printf 'initos qemu firmware fixture\n' > "${fixture_root}/firmware/test/fixture.txt"
    mkfs.erofs --all-root --force-uid=0 -T0 -zlz4 \
        "${ARTIFACTS}/img/firmware.erofs" \
        "${fixture_root}/firmware"
    SECRETS="${keys}" "${src}/sidecar/bin/sign.sh" image "${ARTIFACTS}/img" "firmware.erofs"

    mkdir -p "${fixture_root}/modules/kernel"
    printf 'initos qemu modules fixture for %s\n' "${kernel_release}" \
        > "${fixture_root}/modules/kernel/fixture.txt"
    mkfs.erofs --all-root --force-uid=0 -T0 -zlz4 \
        "${ARTIFACTS}/img/modules-${kernel_release}.erofs" \
        "${fixture_root}/modules"
    SECRETS="${keys}" "${src}/sidecar/bin/sign.sh" image \
        "${ARTIFACTS}/img" "modules-${kernel_release}.erofs"
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
    build_rust
    build_initos
    build_boot
    build_bin
    build_qemu_test
fi
