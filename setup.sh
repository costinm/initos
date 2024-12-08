#!/bin/sh

export SRCDIR=${SRCDIR:-$(pwd)}
export OUT=${OUT:-/x/vol/initos}
export REPO=${REPO:-git.h.webinf.info/costin}

# Build the USB and disk images using the 'recovery-full' - which includes kernel,
# modules, firmware.
full() {
  images
  sign
}

# Sign will use $HOME/.ssh/initos directory to create a private root key and EFI signing
# keys on first run.
# 
# Will use the key to sign UKI EFI files and the images, and to add additional config
# files (wpa_config, signatures, domain, etc). 
# 
# It expects a /x/initos volume containing the images/ and boot/ files.
sign() {
  set -x
  # in case of changes
  VOLS="$VOLS -v ${SRCDIR}/recovery/sbin:/opt/initos/bin"

  # /x will be the rootfs btrfs, with subvolumes for recovery, root, modules, etc
  VOLS="$VOLS -v ${OUT}:/x/initos"

  SECRET=${HOME}/.ssh/initos
  mkdir -p ${SECRET}/uefi-keys

  if [ ! -f ${SECRET}/domain ]; then
    echo -n initos.mesh.internal. > ${SECRET}/domain
  fi
  DOMAIN=$(cat ${SECRET}/domain)
  
  # Inside the host or container - initos files will be under /initos (for now)
  docker run -it --rm -e DOMAIN=${DOMAIN} \
      ${VOLS} \
      -v ${HOME}/.ssh/initos/uefi-keys:/etc/uefi-keys \
    ${REPO}/initos-full:latest /opt/initos/bin/setup-initos sign
}

# Dist creates the RO images and the files required for generating the EFI.
# Should be run on an empty directory (will not re-run), when the kernel, modules
# firmware or upstream binaries change.
# 
# Can be slow.
images() {
  
  # Only used on the git repo, to use locally update files.
  VOLS="$VOLS -v ${SRCDIR}/recovery/sbin:/opt/initos/bin"

  VOLS="$VOLS -v ${OUT}:/x/initos"

  docker run -it --rm \
      ${VOLS} \
    ${REPO}/initos-full:latest /opt/initos/bin/setup-initos dist
}

images_host() {
  VOLS="$VOLS -v ${SRCDIR}/recovery/sbin:/opt/initos/bin"
  VOLS="$VOLS -v /lib/firmware:/lib/firmware"
  VOLS="$VOLS -v /lib/modules:/lib/modules"
  VOLS="$VOLS -v /boot:/boot"

  VOLS="$VOLS -v ${OUT}:/x/initos"

  docker run -it --rm \
      ${VOLS} \
    ${REPO}/initos-recovery:latest /opt/initos/bin/setup-initos dist

}


push() {
  local host=${1:-host8}

  # Expects /z/initos/usb to be the USB EFI partition and 
  # /z/initos/boot/efi to be the 'canary' EFI partition.
  rsync -avuz ${OUT}/ ${host}:/z/initos/ \
     --exclude virt/ --exclude boot/ --exclude work/
}

test() {
  local host=${1:-host8}
  set -e

  sign
  push

  ssh ${host} "sync && reboot -f &"
}

testall() {
  local host=${1:-host8}
  set -e
  ./dbuild.sh all
  ./dbuild.sh deb
  sudo rm -rf ${OUT}/img
  images
  sign
  push

  ssh ${host} "sync && reboot -f &"
}

if [ $# -eq 0 ]; then
  images
  sign
else 
  $*
fi
