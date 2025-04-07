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
if [ -f ${SECRET}/env ]; then 
  source ${SECRET}/env
fi

export SRCDIR=${SRCDIR:-$(pwd)}

# Output generated here
WORK=${HOME}/.cache/initos/efi

IMAGE_SIGNER=ghcr.io/costinm/initos-efi-signer:latest

mkdir -p ${SECRET}/uefi-keys ${WORK}

echo "Signing keys and configs to sign in ${SECRET}"
echo "Will generate EFI files on ${WORK} - copy to USB EFI for initial setup"
echo "Signer image: ${IMAGE_SIGNER}"
echo
echo "Other commands: "
echo "buildall - fetch latest deb kernel and arch, rebuild all"
echo "ui - modify the 'initos' container, add sway/firefox"
echo "build - will rebuild the sqfs and initrd after changes to the root image or scripts (slow)"
echo "push HOST A|B - will sign and push the efi to the host and reboot"
echo
echo

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

  buildah containers --format {{.ContainerName}} | grep ${POD} > /dev/null
  if [[ $? -ne 0 ]]; then
     buildah --name initos from ${IMAGE_SIGNER}
     echo starting 
  fi

  # Update with latest files, optional
  buildah copy $POD rootfs /

  # Create signed UKI (and unsigned one)
  VOLS="$VOLS -v ${SECRET}:/config" 
  VOLS="$VOLS -v ${WORK}:/data" 
  buildah run $VOLS $POD -- setup-efi efi $*
}

# Build the EFI using docker.
defi() {
  docker run -it --rm  \
     -v ${SECRET}:/config \ 
     -v ${WORK}:/data \ 
    ${IMAGE_SIGNER} setup-efi $*
}

# Rebuild the builder image.
# It cleans and get current kernel and alpine.
buildall() {
  ${SRCDIR}/rootfs/sbin/setup-builder all $*
}

# Patch the alpine rootfs container to add UI.
# Call build to rebuild the sqfs.
ui() {
  ${SRCDIR}/rootfs/sbin/setup-builder initos_efi_add /sbin/setup-recovery wui
  ${SRCDIR}/rootfs/sbin/setup-builder initos_efi_add setup-recovery ui2
}

xui() {
  ${SRCDIR}/rootfs/sbin/setup-builder initos_efi_add setup-recovery xui_alpine
  ${SRCDIR}/rootfs/sbin/setup-builder initos_efi_add setup-recovery ui2
}

# Copy the files from current dir to the image and rebuild the sqfs
# an default initrd.
build() {
  # This creates the rootfs using the files in the initos_base 
  # plus any files we may add.
  # 
  # For example 'ui' will add the alpine UI.
  ${SRCDIR}/rootfs/sbin/setup-builder initos_efi_update $*
  # The sqfs is cached
  rm ${WORK}/initos/*
}

# Buildc is a clean build of the image and sqfs - dropping the UI
# and other additions
buildc() {
  # This creates the rootfs using the files in the initos_base 
  # plus any files we may add.
  # 
  # For example 'ui' will add the alpine UI.
  ${SRCDIR}/rootfs/sbin/setup-builder initos_efi_builder $*
  # The sqfs is cached
  rm ${WORK}/initos/*
}


# Build the base images (slow). Alternative is to pull from 
# github.
buildbase() {
  ${SRCDIR}/rootfs/sbin/setup-builder clean $*
  ${SRCDIR}/rootfs/sbin/setup-builder debkernel $*
  ${SRCDIR}/rootfs/sbin/setup-builder initos_base $*
}

##### PUSH to machines

# in ~/.ssh/initos/env
# - define CANARY, USB to point to machines used for testing secure and insecure boot.


push() {
  host=${1:-${CANARY}}
  next=${2:-B}
  set -xe

  # Build the EFI for the host, including host-specific configs
  # This packages the configs to a CPIO and signs.
  # Should not be large, just signing keys and core configs
  efi $host

  ssh $host "mkdir -p /boot/b; mount LABEL=BOOT${next} /boot/b"

  rsync -ruvz --inplace ${WORK}/  $host:/boot/b

  ssh $host "umount /boot/b"

  if [ "$next" = "B" ]; then
    ssh $host "chroot /initos/rootfs efibootmgr -n 1002 && reboot"
  else
    ssh $host "chroot /initos/rootfs efibootmgr -n 1001 && reboot"
  fi

  # TODO: sleep and check, set permanent boot order
}

if [ -z ${1+x} ] ; then
  efi
else
  $*
fi


