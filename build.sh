#!/bin/bash

# Build the InitOS images and EFI files, using Buildah, user-space. 
# A separate build using Dockerfile is also available.
#
# Buildah userspace notes:
# - It is not possible to do mknod on rootless - so inside the 
# container it won't be able to do debootstrap or similar. 
# - uses ~/.local/share/containers/ 


SRCDIR=$(dirname "$(readlink -f "$0")")
. ${SRCDIR}/env

export POD=${POD:-initos}
# Output generated here
export WORK=${HOME}/.cache/${POD}

# git.h.webinf.info/costin
REPO=${REPO:-ghcr.io/costinm/initos}
TAG=${TAG:-latest}

# For the docker build variant.
export DOCKER_BUILDKIT=1

set -e


# Rebuild the builder image.
# It cleans and get current kernel and alpine.
# About 8 min
all() {
  rm -rf ${WORK}/*
  buildah rm kernel || true
  # Get the latest kernel. 'kernel' container
  # When kernel changes, rebuild everything.
  kernel
  
  buildah rm initos-sidecar || true

  sidecar

  # The remaining steps are are using the images built above.
  # The sidecar requires kernel 'save_boot' to be called first.

  # Generate the copy the kernel+modules to /data
  gen
}

# Gen is called after the 2 containers are build or pulled/started
gen() {
  _run_cmd kernel /sbin/setup-deb save_boot
  # Generate the initrd files (on /data), virtual initrd is copied 
  # over to the sidecar container 
  initrd

  # Build the SQFS with the kernel.
  updateDeb
  updateSidecar

  ./sign.sh
}

# kernel (on new debian releases, very slow) - includes modules, firmware and nvidia driver, 
# plus base packages. 
# Can be extended with more debian packages.
# This also generates /data/efi/initos/initos.sqfs and /data/lib, boot for later stages.
kernel() {
  _build_cmd debian:bookworm-slim kernel /sbin/setup-deb debian_rootfs_base

}

# The image for building and signing the EFI
# signer() {
#   _build_cmd alpine:edge initos-builder  setup-efi install
# }


# Generate the initrd images, using initos-builder and the kernel modules
# Must be regenerated after kernel changes - the scripts are patched when generating the EFI.
initrd() {
  buildah copy initos-sidecar rootfs/sbin /sbin
  buildah copy initos-sidecar sidecar/sbin /sbin

  buildah run -v ${WORK}:/data \
    -v ${WORK}/boot:/boot \
    -v ${WORK}/lib/modules:/lib/modules \
    -v ${WORK}/lib/firmware:/lib/firmware \
    initos-sidecar \
      setup-initos setup_initrd
}

# Build the initos alpine rootfs.
sidecar() {
  _build_cmd alpine:edge initos-sidecar  setup-sidecar install

  # Add UI and dev tools to the sidecar - useful, may switch to an option
  # later
  _build_cmd alpine:edge initos-sidecar  setup-sidecar add_extra

  # Add the sidecar-specific files
  buildah copy initos-sidecar sidecar/etc /etc

}


# Can run commands with 'buildah run kernel' - this updates the sqfs.
updateDeb() {
  rm -rf ${WORK}/efi/initos*
  _run_cmd kernel setup-deb sqfs /data/efi/initos
  #"$@"
}

updateSidecar() {
  rm -rf ${WORK}/efi/sidecar*
  _run_cmd initos-sidecar setup-initos sqfs /data/efi/initos sidecar
  #"$@"
}

# Start a container using $1 image, with the name $2 - rest of the args are run in the container.
# The work dir is mounted as /data, with additional mounts for apt and apk cache.
_build_cmd() {
  local BASE=$1
  local POD=$2
  shift; shift

  if ! buildah containers --format '/{{.ContainerName}}/' | grep "/${POD}/" > /dev/null; then
 # if [ $? -ne 0 ]; then
     buildah pull ${BASE}
     buildah --name ${POD} from ${BASE}
    # Cache directories - deb and alpine
    mkdir -p ${WORK}/apkcache ${WORK}/lib_cache ${WORK}/apt
  fi


  _run_cmd ${POD} "$@"
}

# Run a command in the $1 container.
# Same volumes.
_run_cmd() {
  local POD=$1
  shift

  local VOLS="$VOLS -v ${WORK}/lib_cache:/var/lib/cache"
  VOLS="$VOLS -v ${WORK}/apkcache:/etc/apk/cache"
  VOLS="$VOLS -v ${WORK}/apt:/var/cache/apt/archives"

  VOLS="$VOLS -v ${WORK}:/data"

  buildah copy ${POD} rootfs/sbin /sbin
  buildah copy ${POD} sidecar/sbin /sbin

  buildah run ${VOLS} ${POD} -- "$@"
  buildah copy ${POD} rootfs/etc /etc
}

# Experimental targets

# Build the docker images (normally done by the github actions)
dockerc() {
   docker build --network host --target kernel  . -t ${REPO}/initos-rootfs:${TAG}
   docker build --network host --target builder  . -t ${REPO}/initos-builder:${TAG}
   docker build --network host --target sidecar  . -t ${REPO}/initos-sidecar:${TAG}
}


if [ -z "${1+x}" ] ; then
  echo "Building the images for InitOS kernel, root and EFI builder"
  echo
  echo " all - clean build of all 3"
  echo
  echo " kernel - latest debian kernel (kernel)"
  echo " signer - alpine-based EFI builder and signer"
  echo " initrd - regenerate the initrd files"
  echo " sidecar - alpine-based sidecar"
  echo 
  echo " update - Updates the SQFS and initrd files if local changes are made"
  
else
  "$@"
fi


