#!/usr/bin/env bash
#
# build.sh — Build the artifacts using build_NAME:
# - rust 'initos' binary
# - initrd.img - containing the binary
# - initos.erofs - containing the scripts, binary and busybox
# 
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

src=${src:-${PROJECT_ROOT}}

PROFILE="release"
MUSL_TARGET="x86_64-unknown-linux-musl"

cd "${src}"

PATH=$PATH:${PROJECT_ROOT}/sidecar/bin

out=${out:-${PROJECT_ROOT}/target}

REPO=${REPO:-ghcr.io/costinm/initos}
TAG=${TAG:-latest}

IMG_DIR=${IMG_DIR:-${out}/test/img}
mkdir -p "${out}/test" ${IMG_DIR}

BINARY="target/${MUSL_TARGET}/${PROFILE}/initos"

build_rust() {
    cargo build --release --target "${MUSL_TARGET}" --bin initos
    cargo build --release --target x86_64-unknown-uefi --bin efi
}

# Build ${out}/disks/initos stating and creates the image in
# ${out}/disks/state/img/initos.erofs and the 
# initrd equivalent.
#
# The same binaries (initrd, busybox) are present in both 
# the initrd mode and disk mode.
build_initos() {
	STAGING=${out}/disks/initos
	if [ ! -f ${STAGING}/bin/busybox ]; then
		mkdir -p "${STAGING}"/{bin,c,dev,proc,sys,home,run,etc,tmp,sbin,x,boot,data,z,mnt/data,mnt/root}
		mkdir -p "${STAGING}"/lib/modules "${STAGING}"/lib/firmware

		BUSYBOX="${BUSYBOX:-${src}/prebuilt/bin/busybox}"
		cp "${BUSYBOX}" "${STAGING}/bin/busybox"
		chmod 755 "${STAGING}/bin/busybox"
		
		(
            cd ${STAGING}/bin 
            for applet in $(${STAGING}/bin/busybox --list); do
                ln -s /bin/busybox $applet
            done
    		cd -
		)
	fi

	cp "${src}/sidecar/bin/initos-init" "${STAGING}/bin/initos-init"	
    chmod 755 "${STAGING}/bin/initos-init"

	# /init is the entry point
	cp "${src}/sidecar/bin/initos-initrd" "${STAGING}/init"
	chmod 755 "${STAGING}/init"

	# Include unified initos binary (handles boot, TPM2, fscrypt, verify, mount)
	INITOS_BIN="${src}/target/x86_64-unknown-linux-musl/release/initos"
	cp "${INITOS_BIN}" "${STAGING}/bin/initos"
	chmod 755 "${STAGING}/bin/initos"
	echo "  Included initos binary: ${INITOS_BIN}"

    ROOTFS_IMG="${out}/test/img/initos.erofs"
    
	mkdir -p "$(dirname "${ROOTFS_IMG}")"
    rm -rf "${ROOTFS_IMG}.sig"
    mkfs.erofs --all-root --force-uid=0 -T0 -zlz4 "${ROOTFS_IMG}" "${STAGING}"
    echo "  Created: ${ROOTFS_IMG} ($(du -h "${ROOTFS_IMG}" | cut -f1))"

    INITRD_IMG="${out}/disks/boot/EFI/BOOT/initrd.img"
    mkdir -p "$(dirname "${INITRD_IMG}")"
    (cd "${STAGING}" && find . | sort | cpio --quiet -o -H newc | gzip) >"${INITRD_IMG}"
    echo "  Created: ${INITRD_IMG} ($(ls -lh "${INITRD_IMG}" | awk '{print $5}') )"
    cp $INITRD_IMG prebuilt/boot/EFI/BOOT/initrd.img

	mkdir -p ${out}/disks/state/img
	cp ${ROOTFS_IMG} ${out}/disks/state/img/
}

# No used currently - just the rust binary. Use the 
# unified initos image, with busybox and scripting until
# all can be done in the rust binary

# # Build ${out}/test/initrd.img and copies it to 
# # staging dir ${out}/disks/boot/EFI/BOOT 
# build_initrd() {
#     INITRD_STAGING=$(mktemp -d /tmp/initos-initrd.XXXXX)
#     #trap 'rm -rf "${INITRD_STAGING:-}"' EXIT

#     mkdir -p "${INITRD_STAGING}"/{dev,proc,sys,mnt/data,mnt/root}
#     cp "${BINARY}" "${INITRD_STAGING}/init"
#     chmod 755 "${INITRD_STAGING}/init"


#     mkdir -p ${out}/disks/boot/EFI/BOOT
#     INITRD_IMG="${out}/disks/boot/EFI/BOOT/initrd.img"
#     (cd "${INITRD_STAGING}" && find . | sort | cpio --quiet -o -H newc | gzip) >"${INITRD_IMG}"
#     echo "  Created: ${INITRD_IMG} ($(ls -lh "${INITRD_IMG}" | awk '{print $5}') )"
# }

# Copy the additional files for the boot staging.
# 
build_boot() {
    BOOT_PATH="${out}/disks/boot"
    mkdir -p "${BOOT_PATH}/EFI/BOOT"

    cp ${src}/prebuilt/boot/EFI/BOOT/bzImage ${BOOT_PATH}/EFI/BOOT/
    cp ${src}/prebuilt/boot/EFI/BOOT/initrd.img ${BOOT_PATH}/EFI/BOOT/
    cp ${src}/target/x86_64-unknown-uefi/release/efi.efi ${BOOT_PATH}/EFI/BOOT/BOOTX64.EFI

}

# Build an target/test/state.ext4 disk containing the img/ dir.
# For testing.
build_state() {
    ROOTFS_IMG="${out}/disks/state/img/initos.erofs"

    IMG_SIZE_BYTES=$(stat -c%s "${ROOTFS_IMG}")
    IMG_SIZE_MB=$(( (IMG_SIZE_BYTES + 1048575) / 1048576 ))
    STATE_SIZE_MB=$(( IMG_SIZE_MB + 32 ))
    echo "STATE_SIZE_MB: ${STATE_SIZE_MB} (IMG: ${ROOTFS_IMG})"

    GENIMAGE_DIR=${out}/test

    # TODO: switch to e2tool to replace the file.
    DATA_IMG="state.ext4"
    dd if=/dev/zero of="${GENIMAGE_DIR}/${DATA_IMG}" bs=1M count=${STATE_SIZE_MB} status=none

    /sbin/mkfs.ext4 -q -F -b 4096 \
        -O inline_data,extents,uninit_bg,dir_index,has_journal,verity,encrypt \
        -L "STATE" -d "${out}/disks/state" \
        "${GENIMAGE_DIR}/${DATA_IMG}"
}

# Create target/testd/disk.img creating a full GPT disk
# with everything.
build_gpt() {
    PATH="/usr/sbin:/sbin:${PATH}"

    GENIMAGE_DIR="${out}/test"
    mkdir -p ${GENIMAGE_DIR}


    mkdir -p "${GENIMAGE_DIR}/tmp"

    cat > "${GENIMAGE_DIR}/config.ini" <<GENEOF
    image efi.vfat {
        vfat {}
        mountpoint = "/boot"
        size = 32M
    }
    image disk.img {
        hdimage { partition-table-type = "gpt" }
        partition EFI {
            image = "efi.vfat"
            partition-type-uuid = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
            bootable = true
        }
        partition STATE {
            image = "${out}/test/state.ext4"
        }
    }
GENEOF

    echo "Running genimage..."
    cd "${GENIMAGE_DIR}" && \
    genimage --config config.ini \
        --rootpath ${out}/disks --tmppath tmp \
        --outputpath "${out}/test" \
        --inputpath "${GENIMAGE_DIR}"


    echo "  Disk image:       ${out}/test/disk.img"

}

sign_img() {
    local sec_dir=${SECRETS:-prebuilt/testdata/uefi-keys}
    IMAGE_DIR="${out}/disks/state/img"

    SECRETS=${sec_dir} \
      ./scripts/sign.sh image \
        "${IMAGE_DIR}" initos.erofs
}

# Kernel, initrd should be already in the staging dir
#  ${out}/disks/boot
sign_efi() {
    local sec_dir=${SECRETS:-prebuilt/testdata/uefi-keys}
    local boot=${out}/disks/boot

    cp -a "${src}/prebuilt/boot/"* "${boot}/" || true

    ./scripts/sign.sh efi "${sec_dir}" "${boot}"
}

### Kernel and debian rootfs 
# Using 'cctl' tool.
# First 2 parameters are always COMMAND and CONTAINER_NAME
# For 'run' command, CONTAINER_IMAGE is next followed 
# by shell command.
#
# It creates a ~/.cache/CONTAINER_NAME directory for out
# and mounts current dir as src.
# 
deb() {
    _img
}

debhostui() {
    _img hostui
}

# Creates an image with kernel and debian rootfs
# for kernel development.
kernel_dev() {
    cctl start initos-kernel-dev debian:trixie-slim
    cctl exec initos-kernel-dev /ws/sidecar/bin/setup-deb add_dev_kernel 
}

kernel() {
    cctl exec initos-kernel-dev ${REPO}/initos-kernel-dev /ws/sidecar/bin/setup-deb nvidia
}

nvidia() {
    cctl run initos ${REPO}/initos-kernel-dev /ws/sidecar/bin/setup-deb nvidia
}

_img() {
    local s=${1:-host}

    cctl build ${REPO}/${s} --build-arg SCRIPT=${s} 
    d=$(podman unshare podman image mount ${REPO}/${s})
    
    ROOTFS_IMG="${out}/test/img/initos.erofs"

    podman unshare mkfs.erofs -zlz4hc "${ROOTFS_IMG}" $d
}


if [[ $# -gt 0 ]]; then
    for cmd in "$@"; do
        $cmd
    done
    exit 0
fi

build_rust
build_initos
build_boot

