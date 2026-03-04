#!/usr/bin/env bash
#
# mkrootfs.sh - Create the full test image set for initos QEMU testing.
#
# Creates:
#   1. ROOT-A.img      - Inner ext4 rootfs (busybox + hello world /sbin/init), label ROOTFS
#   2. disk.img        - Disk image with GPT partition containing EFI boot and STATE partition
#   3. initrd.img      - CPIO initrd containing the initos binary as /init
#
# Usage: ./scripts/mkrootfs.sh [output_dir]
#
# Output: all files in output_dir (default: target/test)

set -euo pipefail
PATH="/usr/sbin:/sbin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/target/test}"

src=${src:-${PROJECT_ROOT}}
out=${out:-${OUTPUT_DIR}}

IMG_SIZE_MB="${IMG_SIZE_MB:-16}"
STATE_SIZE_MB="${STATE_SIZE_MB:-64}"


# FS for the outer disk image - STATE partition.
INITOS_FS="${INITOS_FS:-ext4}"

# Source the shared signing tool
source "${src}/sidecar/bin/setup_signed.sh"

mkdir -p "${out}"
STAGING=$(mktemp -d /tmp/initos-rootfs.XXXXX)
trap 'rm -rf "${STAGING:-}"' EXIT

mkbb() {
    # Step 1: Create inner rootfs (ROOT-A.img)
    echo "=== Creating inner rootfs (ROOT-A.img) ==="

    mkdir -p "${STAGING}"/{bin,dev,proc,sys,etc,tmp,sbin}

    BUSYBOX="${src}/prebuilt/bin/busybox"
    if [[ ! -f "${BUSYBOX}" ]]; then
        echo "ERROR: busybox not found at ${BUSYBOX}"
        exit 1
    fi
    cp "${BUSYBOX}" "${STAGING}/bin/busybox"
    chmod 755 "${STAGING}/bin/busybox"

    # Create busybox symlinks
    for cmd in sh ls cat echo mkdir mount umount sleep poweroff reboot; do
        ln -s busybox "${STAGING}/bin/${cmd}"
    done

    # Create the hello-world init
    cat >"${STAGING}/sbin/init" <<'INITSH'
#!/bin/sh
/bin/busybox mount -t proc proc /proc 2>/dev/null || true
/bin/busybox mount -t sysfs sysfs /sys 2>/dev/null || true
/bin/busybox mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
echo "===== Hello World from initos! ====="
echo "Kernel: $(/bin/busybox uname -r)"
echo "Init PID: $$"
/bin/busybox poweroff -f
INITSH
    chmod 755 "${STAGING}/sbin/init"
}


# Create the inner rootfs ext4 image with label ROOTFS
mkroota() {
    ROOTFS_IMG="${out}/ROOT-A.img"
    dd if=/dev/zero of="${ROOTFS_IMG}" bs=1M count=${IMG_SIZE_MB} status=none
    mkfs.ext4 -q -F -b 4096 -L ROOTFS -d "${STAGING}" "${ROOTFS_IMG}"
    echo "  Created: ${ROOTFS_IMG} ($(du -h "${ROOTFS_IMG}" | cut -f1))"
}

mkbb
mkroota

# Step 2: Sign ROOT-A.img
echo ""
echo "=== Signing ROOT-A.img ==="

SIGN_DIR="${out}/signing"
mkdir -p "${SIGN_DIR}"

echo "Computing offline digest..."
create_signed_offline "${ROOTFS_IMG}" "${SIGN_DIR}" "${SIGN_DIR}"

PUB_KEY_HEX=$(cat "${SIGN_DIR}/pub_key.hex")

# Step 3: Create initrd with initos binary
echo ""
echo "=== Creating initrd ==="
${src}/scripts/build.sh

# Step 4: Create GPT disk image
echo ""
echo "=== Creating GPT disk image with EFI + STATE partition (${INITOS_FS}) ==="

GENIMAGE_DIR="${out}/genimage"

mkdir -p "${GENIMAGE_DIR}/rootpath_data/img"
cp "${ROOTFS_IMG}" "${GENIMAGE_DIR}/rootpath_data/img/ROOT-A.img"
cp "${SIGN_DIR}/ROOT-A.img.sig" "${GENIMAGE_DIR}/rootpath_data/img/ROOT-A.img.sig"

if [[ "${INITOS_FS}" == "btrfs" ]]; then
	BTRFS_SIZE_MB=$((STATE_SIZE_MB < 128 ? 128 : STATE_SIZE_MB))
	DATA_IMG="data.btrfs"
	# Create empty file
	dd if=/dev/zero of="${GENIMAGE_DIR}/${DATA_IMG}" bs=1M count=${BTRFS_SIZE_MB} status=none
	# Format it with the rootdir
	/sbin/mkfs.btrfs -r "${GENIMAGE_DIR}/rootpath_data" \
        -L "STATE" "${GENIMAGE_DIR}/${DATA_IMG}"
	PART_IMG="${DATA_IMG}"
else
	DATA_IMG="data.ext4"
	dd if=/dev/zero of="${GENIMAGE_DIR}/${DATA_IMG}" bs=1M count=${STATE_SIZE_MB} status=none
	mkfs.ext4 -q -F -b 4096 \
      -O extents,uninit_bg,dir_index,has_journal,verity,encrypt \
      -L "STATE" -d "${GENIMAGE_DIR}/rootpath_data" \
      "${GENIMAGE_DIR}/${DATA_IMG}"
	PART_IMG="${DATA_IMG}"
fi

mkdir -p "${GENIMAGE_DIR}/rootpath/boot"

if [[ -d "${src}/prebuilt/boot" ]]; then
	cp -a "${src}/prebuilt/boot/"* "${GENIMAGE_DIR}/rootpath/boot/" || true
fi

if [[ -f "${src}/prebuilt/boot/EFI/BOOT/limine.conf-tmpl" ]]; then
	echo "Generating limine.conf from template..."
	SHA_BZIMAGE=$(b2sum "${GENIMAGE_DIR}/rootpath/boot/EFI/LINUX/bzImage" | cut -d' ' -f1)
	SHA_INITRD=$(b2sum "${GENIMAGE_DIR}/rootpath/boot/EFI/LINUX/initrd.img" | cut -d' ' -f1)
	sed -e "s/\${INITOS_PUB_KEY}/${PUB_KEY_HEX}/g" \
	    -e "s/\${SHA_BZIMAGE}/${SHA_BZIMAGE}/g" \
	    -e "s/\${SHA_INITRD}/${SHA_INITRD}/g" \
	    "${src}/prebuilt/boot/EFI/BOOT/limine.conf-tmpl" > "${GENIMAGE_DIR}/rootpath/boot/EFI/BOOT/limine.conf"
fi
CFGSHA=$(cat "${GENIMAGE_DIR}/rootpath/boot/EFI/BOOT/limine.conf" | b2sum | cut -d' ' -f1)

mkdir -p "${GENIMAGE_DIR}/rootpath/boot/EFI/BOOT"
BOOTX64_EFI="${GENIMAGE_DIR}/rootpath/boot/EFI/BOOT/BOOTX64.EFI"

if [[ ! -f "${BOOTX64_EFI}" ]]; then
	echo "Downloading BOOTX64.EFI..."
	curl -L "https://github.com/limine-bootloader/limine/raw/v10.8.2-binary/BOOTX64.EFI" -o "${BOOTX64_EFI}"
fi

echo ${CFGSHA}
echo limine enroll-config "${BOOTX64_EFI}" "${CFGSHA}"

limine enroll-config "${BOOTX64_EFI}" "${CFGSHA}"

echo "Signing BOOTX64.EFI..."
sbsign --key "${src}/prebuilt/testdata/uefi-keys/db.key" \
       --cert "${src}/prebuilt/testdata/uefi-keys/db.crt" \
       --output "${BOOTX64_EFI}" "${BOOTX64_EFI}"



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
		image = "${PART_IMG}"
	}
}
GENEOF

echo "Running genimage..."
cd "${GENIMAGE_DIR}" && genimage --config config.ini --rootpath rootpath --tmppath tmp --outputpath "${out}" --inputpath "${GENIMAGE_DIR}"


echo "  Created: ${out}/disk.img"
echo ""
echo "=== Image set complete ==="
echo "  Inner rootfs:     ${ROOTFS_IMG}"
echo "  Disk image:       ${out}/disk.img"
echo "  Initrd:           ${out}/initrd.img"
echo "  Pub key:          ${PUB_KEY_HEX}"
