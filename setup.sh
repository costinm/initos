#!/bin/bash

# Setup will create the files for th efi partition, including
# the signed UKI, using the initos image.

# Additional configs that will be added to the signed UKI:
# - authorized_keys
# - domain
# - root.pem - mesh root certificate
# - hosts ?
# - mesh.json - mesh json configuration
SECRET=${HOME}/.ssh/initos
mkdir -p ${SECRET}/uefi-keys
export SRCDIR=${SRCDIR:-$(pwd)}

WORK=/x/vol/boot

# Sign will use $HOME/.ssh/initos directory to create a private root key and EFI signing
# keys on first run.
#
# Will use the key to sign UKI EFI files and the images, and to add additional config
# files (wpa_config, signatures, domain, etc).
#
# It expects a /x/initos volume containing the images/ and boot/ files.
#
# Sign runs a container with the recovery image and keys mounted.
# It produces a set of UKI images, including the signed one.
#
# Requires the sqfs file and verity hash to be already available.
sign() {
  local POD=recovery

  # Update with latest files, optional
  buildah copy $POD recovery/ /

  # Create signed UKI (and unsigned one)
  VOLS="-v ${SECRET}/uefi-keys:/etc/uefi-keys" 
  VOLS="$VOLS -v ${WORK}:/x/initos" 
  buildah run $VOLS $POD -- setup-initos sign2
}

dsign() {
  docker run -it --rm  \
     -v ${SECRET}/uefi-keys:/etc/uefi-keys \ 
     -v ${WORK}:/x/initos \ 
    ${REPO}/initos:latest /sbin/setup-initos sign2
}

# Same thing, using docker - copy latest files
dsign2() {
  # in case of changes
  VOLS="-v ${SECRET}/uefi-keys:/etc/uefi-keys" 
  VOLS="$VOLS -v ${WORK}:/x/initos" 
  VOLS="$VOLS -v ${SRCDIR}/recovery/sbin:/opt/initos/sbin"

  # Inside the host or container - initos files will be under /initos (for now)
  docker run -it --rm  \
      ${VOLS} \
    ${REPO}/initos:latest /opt/initos/sbin/setup-initos sign2
}

##### PUSH to machines

# This is the USB recovery disk - mounts the original
# efi as efi2.
push_recovery_usb() {
  host=${1:-usb}

  scp -r -O ${WORK}/usb/EFI $host:/boot/efi/
  scp -r -O ${WORK}/secure $host:/boot/efi/
  scp -r -O ${WORK}/img $host:/boot/efi/initos
}

push_recovery() {
  host=${1:-usb}

  scp -r -O ${WORK}/img $host:/boot/efi2/initos
  scp -r -O ${WORK}/secure/EFI $host:/boot/efi2/
}

push_usb() {
  host=${1:-host18}

  ssh $host mount /dev/sda1 /mnt/usb

  scp -r -O ${WORK}/usb/EFI $host:/mnt/usb
  scp -r -O ${WORK}/secure $host:/mnt/usb

  ssh $host umount /mnt/usb
}

push_usb_all() {
  host=${1:-host18}

  ssh $host mount /dev/sda1 /mnt/usb

  scp -r -O ${WORK}/usb/EFI $host:/mnt/usb
  scp -r -O ${WORK}/secure $host:/mnt/usb
  scp -r -O ${WORK}/img $host:/mnt/usb/initos

  ssh $host umount /mnt/usb
}

push_secure() {
  host=${1:-host18}

  scp -r -O ${WORK}/secure/EFI $host:/boot/efi
}

push_secure_all() {
  host=${1:-host18}

  scp -r -O ${WORK}/img $host:/boot/efi/initos
  scp -r -O ${WORK}/secure/EFI $host:/boot/efi
}

$*


