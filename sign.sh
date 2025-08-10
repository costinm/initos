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

# Build the EFI using docker.
# Sign is the only one with the EFI keys mounted
sign() {
  IMG=${REPO}/intios-signer:${TAG}
  IMG=sidecar
  # Create signed UKI (and unsigned one)
  VOLS="$VOLS -v ${SECRET}:/var/run/secrets" 
  VOLS="$VOLS -v ${HOME}/config:/config" 
  #VOLS="$VOLS -v ${WORK}:/data" 

  # if [ -d ${WORK}/boot ]; then
  #   VOLS="$VOLS -v ${WORK}/boot:/boot -v ${WORK}/boot/modules:/lib/modules -v ${WORK}/boot/firmware:/lib/firmware "
  # fi

  #VOLS="$VOLS --mount type=image,source=efi,destination=/data/efi" 

  podman run -v ${WORK}/efi:/data/efi \
	      -v ${SRCDIR}:/src \
		    ${VOLS} ${IMG} \
      /sbin/setup-efi efi "$@"
}

sign "$@"


