#!/bin/bash

# Build the InitOS images and EFI files, using Buildah, user-space. 
# A separate build using Dockerfile is also available.
#
# Buildah userspace notes:
# - It is not possible to do mknod on rootless - so inside the 
# container it won't be able to do debootstrap or similar. 
# - uses ~/.local/share/containers/ 


SRCDIR=$(dirname "$(readlink -f "$0")")

export POD=${POD:-initos}

# Output generated here
export WORK=${HOME}/.cache/${POD}

# git.h.webinf.info/costin
REPO=${REPO:-ghcr.io/costinm/initos}
TAG=${TAG:-latest}

# For the docker build variant.
export DOCKER_BUILDKIT=1

set -e

docker=podman

sidecar() {
   ${docker} build  . -t ${REPO}/initos-sidecar:${TAG}
}

# Generate the unsigned sidecar.sqfs 
sqfs() {
   ${docker} build  . --target efi \
    --output ${WORK}/efi
}


all() {
  sidecar
   ${docker} build --target alpine-dev  . -t ${REPO}/initos-dev:${TAG}
   ${docker} build --target alpine-ui  . -t ${REPO}/initos-ui:${TAG}
}

# cpimg copies the content of an image to a dir. 
cpimg() {
  SRC=$1
  DST=$2

  podman run --rm \
    --mount type=image,source=$SRC,destination=/src \
    -v $DST:/out \
    alpine \
      cp -a /src/* /out/
}


# Push to an machine not use secure boot.
# Using verity does not change the security posture - so no need for the extra
# complexity and overhead, sidecar and modloop are directories.
#
# Upgrade is much simpler and forgiving - the host still has an encrypted
# disk to store secrets, which can be unlocked by a trusted machine using 
# ssh, so as protected in case the machine is stolen, but not against the
# evil maid.
push() {
  host=${1:-${CANARY}}
  shift

  set -xe

  # Unlike secure boot, the configs are not added (and signed) in the EFI.
  # The generic EFI can be used.

  scp -O ${WORK}/efi/InitOS-unsigned.EFI $host:/boot/efi/EFI/BOOT/BOOTx64.EFI
}

if [ -z "${1+x}" ] ; then
  echo "Building the images for InitOS kernel, root and EFI builder"
  echo
  echo " all - clean build of all 3"
  echo
  echo " signer - alpine-based EFI builder and signer"
  echo " sidecar - alpine-based sidecar"
  
else
  "$@"
fi


