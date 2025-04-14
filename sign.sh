#!/bin/sh

# Sign the UKI and assemble the EFI image.


SRCDIR=$(dirname "$(readlink -f "$0")")
#export SRCDIR=${SRCDIR:-$(pwd)}
. ${SRCDIR}/env

SECRET=${HOME}/.ssh/initos
if [ -f ${SECRET}/env ]; then 
  . ${SECRET}/env
fi

# The container with the tools and images to sign.
POD=${POD:-initos}

# Output generated here
WORK=${HOME}/.cache/${POD}

IMAGE_SIGNER=${REPO}/initos-efi-signer:latest

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

  buildah containers --format {{.ContainerName}} | grep ${POD} > /dev/null
  if [ $? -ne 0 ]; then
     buildah --name ${POD} from ${IMAGE_SIGNER}
     echo starting 
  fi

  # Update with latest files, optional
  buildah copy ${POD} rootfs /

  # Create signed UKI (and unsigned one)
  VOLS="$VOLS -v ${SECRET}:/config" 
  VOLS="$VOLS -v ${WORK}:/data" 

  if [ -d ${WORK}/boot ]; then
    VOLS="$VOLS -v ${WORK}/boot:/boot -v ${WORK}/lib/modules:/lib/modules -v ${WORK}/lib/firmware:/lib/firmware "
  fi
  buildah run $VOLS \
     ${POD} -- setup-efi efi $*
}

# Build the EFI using docker.
defi() {
  docker run -it --rm  \
     -v ${SECRET}:/config \ 
     -v ${WORK}:/data \ 
    ${IMAGE_SIGNER} setup-efi $*
}



efi "$@"


