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
out=${out:-${src}/target}

PROFILE="release"
MUSL_TARGET="x86_64-unknown-linux-musl"

cd "${src}"

PATH=${src}/sidecar/bin:$PATH

cctl() {
    OUT_DIR="${out}/c/${POD:-initos_dev}" command cctl "$@"
}
REPO=${REPO:-ghcr.io/costinm/initos}
TAG=${TAG:-latest}

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
		mkdir -p "${STAGING}"/{dev,proc,sys,sysroot,home,mnt,run,etc,tmp,x,data,z,a,nix,opt/initos/bin,opt/busybox/bin,usr/bin,usr/sbin,usr/lib,usr/lib64}
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
    
    INITOS_IMG=${ROOTFS_IMG}
    HASH_OFFSET=$(stat -c %s "${INITOS_IMG}")
    VERITY_OUT=$(/sbin/veritysetup format --hash-offset=$HASH_OFFSET "${INITOS_IMG}" "${INITOS_IMG}")
    
    ROOT_HASH=$(echo "$VERITY_OUT" | awk '/Root hash:/ {print $3}')
    SALT=$(echo "$VERITY_OUT" | awk '/Salt:/ {print $2}')
    DATA_BLOCKS=$(echo "$VERITY_OUT" | awk '/Data blocks:/ {print $3}')
    
    echo "ROOT_HASH=$ROOT_HASH" > "${IMG_DIR}/initos.verity.txt"
    echo "SALT=$SALT" >> "${IMG_DIR}/initos.verity.txt"
    echo "HASH_OFFSET=$HASH_OFFSET" >> "${IMG_DIR}/initos.verity.txt"
    echo "DATA_BLOCKS=$DATA_BLOCKS" >> "${IMG_DIR}/initos.verity.txt"

    LENGTH=$((DATA_BLOCKS * 8))
    HASH_START_BLOCK=$(( (HASH_OFFSET / 4096) + 1 ))
    
    DM_STR="vroot,,,ro,0 ${LENGTH} verity 1 PARTLABEL=INITOSA PARTLABEL=INITOSA 4096 4096 ${DATA_BLOCKS} ${HASH_START_BLOCK} sha256 ${ROOT_HASH} ${SALT}"
    cat > "${IMG_DIR}/config.verity" <<EOF
 root=/dev/dm-0 rootwait rootfstype=erofs dm-mod.create="${DM_STR}" dm-mod.waitfor=PARTLABEL=INITOSA
EOF
    
    DM_STR="vroot,,,ro,0 ${LENGTH} verity 1 PARTLABEL=INITOSB PARTLABEL=INITOSB 4096 4096 ${DATA_BLOCKS} ${HASH_START_BLOCK} sha256 ${ROOT_HASH} ${SALT}"
    cat > "${IMG_DIR}/configB.verity" <<EOF
 root=/dev/dm-0 rootwait rootfstype=erofs dm-mod.create="${DM_STR}" dm-mod.waitfor=PARTLABEL=INITOSB
EOF
   
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

# 3.1 Copy the additional files for the boot staging.
# Includes the initos.erofs verity signature for the alternative initrd-free
# testing.
# At this point the disks/boot is complete but unsigned. 
build_boot() {
    BOOT_PATH="${out}/disks/boot"
    mkdir -p "${BOOT_PATH}/EFI/BOOT"

    cp ${src}/prebuilt/boot/EFI/BOOT/bzImage ${BOOT_PATH}/EFI/BOOT/

    # Both limine and initos loaders included.
    # initos will be signed and used with efibootmgr.
    cp ${src}/prebuilt/boot/EFI/BOOT/BOOTX64.EFI ${BOOT_PATH}/EFI/BOOT/limine.EFI
    cp ${src}/target/x86_64-unknown-uefi/release/efi.efi ${BOOT_PATH}/EFI/BOOT/initos.EFI

    # For testing use initos as default.
    cp ${src}/target/x86_64-unknown-uefi/release/efi.efi ${BOOT_PATH}/EFI/BOOT/BOOTX64.EFI

    cp ${src}/prebuilt/boot/EFI/BOOT/limine.conf ${BOOT_PATH}/EFI/BOOT/limine.EFI

    CMDLINE="loglevel=4 console=tty1"
    CMDLINE="${CMDLINE} rootwait net.ifnames=0 panic=10"

    # Will be concatented with config.verity to use a separate 
    # partition instead of initrd.
    echo -n "${CMDLINE} init=/opt/initos/bin/initos-init-ver " \
       > ${BOOT_PATH}/EFI/BOOT/config.ver
    cat ${out}/disks/state/img/config.verity >> ${BOOT_PATH}/EFI/BOOT/config.ver
}

# 4. Build a test env for qemu validation.
# This calls step 3 to rebuild the initrd.
build_qemu_test() {
    local esp_dir="${out}/test_efi"
    local genimage_dir="${out}/test"
    local rootfs_img="${out}/disks/state/img/initos.erofs"
    local initos_init="${INITOS_INIT:-/opt/initos/bin/initos-init-qemu}"
    local keys="${src}/prebuilt/testdata/uefi-keys"

    [ -f "${rootfs_img}" ] || {
        echo "Missing ${rootfs_img}; run build_initos first" >&2
        return 1
    }

    mkdir -p "${esp_dir}/EFI"
    cp -R "${out}/disks/boot/EFI/BOOT" "${esp_dir}/EFI/"

    cat > "${esp_dir}/EFI/BOOT/config" <<EOF
rdinit=/init loglevel=9 console=hvc0 INITOS_INIT=${initos_init} rw iommu=relaxed net.ifnames=0 panic=5
EOF

    sign_qemu_efi

    build_qemu_state
    #build_qemu_gpt
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

    /sbin/mkfs.ext4 -q -F -b 4096 \
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

    "${src}/scripts/sign.sh" efi "${keys}" "${esp_dir}/"
}


### Kernel and debian rootfs 
# Slow - only needed periodically. Kernel is saved to prebuilt.
# Modules/firmware are in the container output.
# 
# Using 'cctl' tool.
# First 2 parameters are always COMMAND and CONTAINER_NAME
# For 'run' command, CONTAINER_IMAGE is next followed 
# by shell command.
#
# It creates a ~/.cache/CONTAINER_NAME directory for out
# and mounts current dir as src.
# 


# Prepares the kernel dev container:
# - start with trixie
# - add deb packages required for building kernel
# Result is ~1.8G base image.
kernel_dev() {
    local POD=${1:-initos-dev}   
    # Kernel 6.12 by default - but not including it.
    # bookworm is 6.6 by default
    POD=${POD} cctl start debian:trixie-slim
    
    POD=${POD} cctl ${src}/sidecar/bin/setup-deb kernel_build_tools 
    podman commit ${POD} ${POD}
}

# Build the kernel in initos-kernel-dev container
# Container must be running - 'podman ps -a' and 'podman start' if already
# created, otherwise it must be built. 
kernel() {
    POD=initos-kernel-dev cctl start initos-dev
    POD=initos-kernel-dev cctl ${src}/sidecar/bin/setup-kernel kernel 

    # out: ~/.cache/initos-kernel-dev/img
    # 399M modules, 99M firmware
}

firmware() {
    POD=initos-kernel-dev cctl start initos-dev
    POD=initos-kernel-dev cctl ${src}/sidecar/bin/setup-kernel add_firmware 

    # out: ~/.cache/initos-kernel-dev/img
    # 399M modules, 99M firmware
}

kernel_cloud() {
    POD=initos-kernel-cloud cctl start initos-dev
    POD=initos-kernel-cloud cctl ${src}/sidecar/bin/setup-kernel kernel_cloud
    # out: ~/.cache/initos-kernel-cloud/img
}

# Build a clean Debian image using the 'setup-deb' script
# (instead of Dockerfile having RUN commands - it starts
# a base container with sleep, runs various commands).
#
# After that it also creates an erofs. Currently about 1.7G from 3.6G raw,
# including dev, UI, chrome, code and most tools I use (restic, rclone,...)
# The script has separate functions for different sets of packages and
# it can build smaller images - using the full set for testing.
_img() {
    local s=${1}

    POD=${s} cctl start debian:trixie-slim
    POD=${s} cctl ${src}/sidecar/bin/setup-deb ${s}

    # podman build -t ${REPO}/${s} --build-arg SCRIPT=${s} .
    #podman commit ${s} ${REPO}/${s} 
    #d=$(podman unshare podman image mount ${REPO}/${s})
    
    d=$(podman unshare podman mount ${s})
    # This is the rootfs for the sleeping container. Bind-mounts are not
    # visible - they are in the private mount space of the container, not
    # on the host.

    rm -rf ${out}/${s}
    ln -s ${d} ${out}/${s}
    ROOTFS_IMG="${out}/test/img/${s}.erofs"

    podman unshare mkfs.erofs -zlz4hc "${ROOTFS_IMG}" $d
}

hostui() {
    _img hostui
}

initos_dev() {
    _img initos_dev
    # Save it as a container image - will be used for 
    # kernel and other containers. Other images are just saved
    # as erofs, to be used as flat images.
    podman commit initos_dev initos_dev
}

initos_devui() {
    _img initos_devui
}


if [[ $# -gt 0 ]]; then
    "$@"
else
    build_rust
    build_initos
    build_initrd
    build_boot
    build_qemu_test
fi
