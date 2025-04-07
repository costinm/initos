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

export SRCDIR=${SRCDIR:-$(pwd)}

# Output generated here
WORK=${HOME}/.cache/initos/efi

mkdir -p ${SECRET}/uefi-keys ${WORK}


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
efi() {
  local POD=initos
  buildah containers --format {{.ContainerName}} | grep initos > /dev/null
  if [[ $? -eq 0 ]]; then
  echo started
  else
  buildah --name initos from ghcr.io/costinm/initos:latest
  echo starting 
  fi

  # Update with latest files, optional
  buildah copy $POD rootfs /

  # Create signed UKI (and unsigned one)
  VOLS="-v ${SECRET}/uefi-keys:/etc/uefi-keys" 
  VOLS="$VOLS -v ${WORK}:/x/vol/boot" 
  buildah run $VOLS $POD -- setup-efi sign $*
}

defi() {
  docker run -it --rm  \
     -v ${SECRET}/uefi-keys:/etc/uefi-keys \ 
     -v ${WORK}:/x/initos \ 
    ${REPO}/initos:latest /sbin/setup-efi sign $*
}


##### PUSH to machines

# test hosts: usb, host19, host8


push_usb() {
  host=${1:-host19}

  ssh $host mount /dev/sda1 /boot/usb
  
  mkdir -p ${WORK}/EFI/BOOT
  cp ${WORK}/initosUSB.EFI ${WORK}/EFI/BOOT/BOOTx64.EFI
  rsync -rvz --inplace ${WORK}/  $host:/boot/usb/

  ssh $host umount /boot/usb
}

push() {
  host=${1:-host8}
  # The partitions are small, can't do temp file
  mkdir -p ${WORK}/EFI/BOOT
  cp ${WORK}/initosA.EFI ${WORK}/EFI/BOOT/BOOTx64.EFI

  rsync -ruvz --inplace ${WORK}/  $host:/boot/b/
}


$*


