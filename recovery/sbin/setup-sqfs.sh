#!/bin/sh

# Create squashfs recovery and module images.
# This is not the recommended approach - using a btrfs volume on the USB install drive
# is simpler and more flexibile, while using 2 partitions (ext2 and verity) is simpler
# for cases where LUKS/TMP2 are not needed.

# A USB stick creation usually involves 'dd' and can also create the btrfs partition
# along with a smaller EFI. Updates to the USB can be done using btrfs just like
# for live systems.

modules() {
  local KERNEL_VERSION=$1

  mkdir -p $DIST/boot-edge
  rm -f $DIST/boot-edge/modloop-lts
  mksquashfs /lib/firmware /lib/modules/${KERNEL_VERSION} $DIST/boot-edge/modloop-lts

}


# Recovery is roughly the same with an install of alpine, with ssh and tools installed,
# and the overlay added.
# Should not contain any user specific data or public keys.
# When building the signed EFI and init - the user keys and public settings may be added.
# Any private data needs to be in the LUKS partition.
squash_recovery() {
  # -one-file-system also works on the host - but not so well in a container.
  cd /
  rm -f ${DIST}/recovery.sqfs
  mksquashfs  . ${DIST}/recovery.sqfs \
    -regex -e "x/.*" -e "lib/modules/.*" -e "lib/firmware/.*" -e "boot/.*" \
     -e "proc/.*" -e "sys/.*" -e "run/.*" -e "work/.*" -e "ws/.*" -e "etc/apk/cache.*"
}

# Use the Alpine ISO image as a base - instead of downloading or building
# firmware or modules.
# efi_patch will use an apline ISO, and patch the initrd with the custom init script.
# Alpine is expected to be in ${WORK}/dist/boot (dist is the content of the EFI/iso disk)
efi_alpine_installer() {
  set -e
  mkdir -p ${DIST} ${WORK}/boot

  # Expects that the modloop is already created, and the cache under ${WORK}/modules may
  # exist.

  local cfgf=$(ls ${DIST}/boot/config-*)

  if [ -z ${cfgf} ] ; then
    if [ ! -f ${WORK}/alpine.iso ]; then
      curl -Lo ${WORK}/alpine.iso https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-standard-3.20.3-x86_64.iso
    fi
    cd ${WORK}/dist
    bsdtar xf ${WORK}/alpine.iso
    cfgf=$(ls ${DIST}/boot/config-*)
  fi

  local cfg=$(basename $cfgf)

  KERNEL_VERSION=${cfg#config-}

  KERNEL=${DIST}/boot/vmlinuz-lts

  [ -z ${KERNEL_VERSION} ] && echo "Missing kernel config" && return
  [ ! -f ${KERNEL} ] && echo "Missing kernel ${KERNEL}" && return

  if [ ! -f /lib/modules/${KERNEL_VERSION}/modules.dep ]; then
      unsquashfs -f -d ${WORK} ${DIST}/boot/modloop-lts
      echo "Expanding modules $(ls /lib/modules/${KERNEL_VERSION})"
      chmod -R 755 /lib/modules/
  fi
  [ ! -f /lib/modules/${KERNEL_VERSION}/modules.dep ] && echo "Missing modules - run squash_linux first" && return

  cp /ws/initos/initramfs/init /init
  echo "MODE=dev" > /etc/initos.conf
  (find /init /etc/initos.conf | sort | cpio --quiet --renumber-inodes -o -H newc | gzip) > ${WORK}/initos-xtra.cpio.gz

  echo "Built initramfs ${img} for ${KERNEL_VERSION}"

  echo "loglevel=6 console=ttyS0 console=tty1 net.ifnames=1 panic=5 debug_init iomem=relaxed modules=loop,squashfs,sd-mod,usb-storage" > /tmp/cmdline

  efi-mkuki \
    -c /tmp/cmdline \
    -o ${DIST}/EFI/BOOT/Alpine-${KERNEL_VERSION}.EFI \
      ${KERNEL}  ${DIST}/boot/initramfs-lts ${WORK}/initos-xtra.cpio.gz
}

$*
