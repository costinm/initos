#!/bin/sh

# Sign the UKI and assemble the EFI image.


SRCDIR=$(dirname "$(readlink -f "$0")")
. ${SRCDIR}/env

SECRET=${HOME}/.ssh/initos
if [ -f ${SECRET}/env ]; then 
  . ${SECRET}/env
fi

# Output generated here
WORK=${DATA:-${HOME}/.cache/initos}

IMAGE_SIGNER=${REPO}/initos-sidecar:latest

mkdir -p ${SECRET}/uefi-keys ${WORK}

# Additional configs that will be added to the signed UKI:
# - authorized_keys
# - domain
# - root.pem - mesh root certificate
# - hosts ?
# - mesh.json - mesh json configuration

echo "Signing keys and configs to sign in ${SECRET}"
echo "Will generate EFI files on ${WORK} - copy to USB EFI for initial setup"
echo "Signer image: ${IMAGE_SIGNER}"

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
  # The pod containing the image to be signed and the utils.

  buildah containers --format {{.ContainerName}} | grep initos-sidecar > /dev/null
  if [ $? -ne 0 ]; then
     buildah --name initos-sidecar from ${IMAGE_SIGNER}
     echo starting 
  fi

  # Update with latest files, optional
  buildah copy initos-sidecar rootfs /
  buildah copy initos-sidecar sidecar /

  # Create signed UKI (and unsigned one)
  VOLS="$VOLS -v ${SECRET}:/var/run/secrets" 
  VOLS="$VOLS -v ${HOME}/config:/config" 
  VOLS="$VOLS -v ${WORK}:/data" 

  if [ -d ${WORK}/boot ]; then
    VOLS="$VOLS -v ${WORK}/boot:/boot -v ${WORK}/lib/modules:/lib/modules -v ${WORK}/lib/firmware:/lib/firmware "
  fi
  #buildah run -t $VOLS initos-sidecar -- bash
  buildah run $VOLS initos-sidecar -- setup-efi efi $*
}

# Use the docker images to build the EFI.
dockerb() {
  VOLS="--rm -v ${WORK}:/data"
  
  docker run ${VOLS}  ${REPO}/intios-rootfs:${TAG} \
     /sbin/setup-initos save_boot

  docker run ${VOLS}  ${REPO}/intios-rootfs:${TAG} \
     /sbin/setup-initos sqfs /data/efi/initos initos

  docker run ${VOLS} --network host ${REPO}/intios-builder:${TAG} \
     /sbin/setup-initos setup_initrd

  docker run ${VOLS}  ${REPO}/intios-sidecar:${TAG} \
    /sbin/setup-initos sqfs /data/efi/initos sidecar

  defi "$@"
}


# Build the EFI using docker.
# Sign is the only one with the EFI keys mounted
defi() {
  docker run ${VOLS}  -v ${SECRET}:/config ${REPO}/intios-sidecar:${TAG} \
      /sbin/setup-efi "$@"
}



efi "$@"


