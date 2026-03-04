#!/bin/bash

# Build the InitOS images and EFI files, using Buildah, user-space. 
# A separate build using Dockerfile is also available.
#
# Buildah userspace notes:
# - It is not possible to do mknod on rootless - so inside the 
# container it won't be able to do debootstrap or similar. 
# - uses ~/.local/share/containers/ 

# TODO: break down the targets so each can build independently
# May keep some with Dockerfile dependencies.

# Build configuration
BASE=$(dirname "$(readlink -f "$0")")
PROJECT_ROOT="$(cd "${BASE}" && pwd)"
PROJECT=$(basename ${PROJECT_ROOT})


BUILD_DIR=${HOME}/.cache/${PROJECT}

src=${PROJECT_ROOT}
out=${BUILD_DIR}


SRCDIR=$(dirname "$(readlink -f "$0")")
. ${SRCDIR}/env

SECRET=${HOME}/.ssh/initos
if [ -f ${SECRET}/env ]; then 
  . ${SECRET}/env
fi

MOUNT_DIR="${BUILD_DIR}/mnt"

export POD=${POD:-initos}

# Output generated here
export WORK=${HOME}/.cache/${POD}
mkdir -p ${WORK}

# git.h.webinf.info/costin
REPO=${REPO:-ghcr.io/costinm/initos}
TAG=${TAG:-latest}

# For the docker build variant.
export DOCKER_BUILDKIT=1

set -e
PATH=${PATH}:${SRCDIR}/sidecar/sbin:${SRCDIR}/sidecar/bin

BIN_DIR=${BIN_DIR:-${BASE}/prebuilt}

## Docker build wrappers - debian
root() {

   # 576M
   #(cd sidecar && cctl build deb-base --target deb-base)
   
   # code-server - 1.15
   # (cd sidecar && cctl build deb-code --target deb-code)
   
   # Base + UI - 800M
   # (cd sidecar && cctl build deb-ui --target deb-ui)

   # All - 1.37
   (cd sidecar && cctl build deb-codeui --target deb-codeui)
}

## Docker build wrappers - alpine
root_alpine() {
   (cd sidecar && cctl build sidecar --target sidecar-base)
  # 1.2G
   (cd sidecar && cctl build initos-dev --target alpine-dev)
   # 2.4
   (cd sidecar && cctl build initos-ui --target alpine-ui )
}

initrd() {
   cctl run sidecar sidecar-initrd /sbin/setup-efi-sign.sh 
}

# Build the EFI using docker.
# Sign is the only one with the EFI keys mounted
sign() {
  local variant=${1:-deb}
  shift

  mkdir -p ${SECRET}/uefi-keys ${WORK}

  VOLS="--mount type=image,source=modloop:${variant},destination=/mnt/modloop" 
  VOLS="$VOLS --mount type=image,source=sidecar-base,destination=/mnt/sidecar" 
  VOLS="$VOLS -v ${HOME}/config:/config" 
  
  # dev - use local shell script.
  #CARGS="--entrypoint /bin/sh"
  CARGS="--entrypoint /ws/signer/sbin/setup-efi"
  
  #VOLS="$VOLS --mount type=image,source=efi,destination=/data/efi" 

  SECRETS=$SECRET CARGS="$CARGS" DATA=${WORK} VOLS="$VOLS" \
    cctl run efi-alpine signer "$@" 
}

push() {
  host=${1:-${CANARY}}
  shift

  if [ "$host" = "virt" ]; then
    push_virt "$@"
    return
  fi

  set -xe

  # Build the EFI for the host, including host-specific configs
  # This packages the configs to a CPIO and signs.
  # Should not be large, just signing keys and core configs
  ${SRCDIR}/sign.sh $host

  newh=$(cat ${WORK}/efi/initos/initos.hash )

  mkdir -p ${WORK}/efi/install
  echo ${host} > ${WORK}/efi/install/hostname

  # Temp while testing, should go to .ssh/initos/hosts/NAME
  cp testdata/test_setup ${WORK}/efi/install/autosetup.sh

  # TODO: this should go to the sidecar, should use the script
  # to mount the alternate partition
  ssh $host /sbin/setup-initos-host upgrade_start ${newh}

  ssh $host rm -f /boot/b/initosA.EFI
  
  # Ignore the timestamp, inplace because the EFI is small (default creates a copy)
  rsync -ruvz -I --inplace ${WORK}/efi/  $host:/boot/b
  
  ssh $host /sbin/setup-initos-host upgrade_end "$@"

  # TODO: sleep and check, set permanent boot order
  # using swapNext
}

patch_initrd() {
  mkdir -p ${build}/qemu/patch
	cp -a ${src}/../initos/sidecar/sbin ${build}/qemu/patch

	(cd ${build}/qemu/patch; \
   		find . \
   | sort  | cpio --quiet --renumber-inodes -o -H newc \
   | gzip) > ${build}/qemu/initos-patch.img
}

extract_initrd() {
  mkdir -p ${build}/initrd-full; 
	(cd ${build}/initrd-full; gzip -dc < ${build}/boot/initos-initrd.img | cpio -id)
}


if [ -z "${1+x}" ] ; then
  echo "Building the images for InitOS kernel, root and EFI builder"
  echo
  echo " all"
  echo
  echo " root - rootfs"
  echo " default - alpine-based sidecar, debian kernel"
  
else
  "$@"
fi


