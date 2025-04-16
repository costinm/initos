#!/bin/bash

# Build the InitOS images and EFI files, using Buildah. A separate build
# using Dockerfile is still available.
#

SRCDIR=$(dirname "$(readlink -f "$0")")
. ${SRCDIR}/env

export POD=${POD:-initos}
# Output generated here
export WORK=${HOME}/.cache/${POD}

# Start a container using $1 image, with the name $2 - rest of the args are run in the container.
# The work dir is mounted as /data, with additional mounts for apt and apk cache.
_build_cmd() {
  local BASE=$1
  local POD=$2
  shift; shift

  buildah containers --format {{.ContainerName}} | grep ${POD} > /dev/null
  if [ $? -ne 0 ]; then
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
  buildah copy ${POD} rootfs/bin /bin
  buildah copy ${POD} rootfs/etc /etc

  buildah run ${VOLS} ${POD} -- "$@"
}

# Rebuild the builder image.
# It cleans and get current kernel and alpine.
all() {
  buildah rm kernel
  kernel
  buildah rm initos-builder
  signer
  initrd
  buildah rm initos-sidecar
  sidecar

  ./sign.sh
}

# kernel (on new debian releases, very slow) - includes modules, firmware and nvidia driver, 
# plus base packages. 
# Can be extended with more debian packages.
# This also generates /data/efi/initos/initos.sqfs and /data/lib, boot for later stages.
kernel() {
  _build_cmd debian:bookworm-slim kernel /sbin/setup-initos debian_rootfs
}

# The image for building and signing the EFI
signer() {
  _build_cmd alpine:edge initos-builder  setup-efi install
}


# Generate the initrd images, using initos-builder and the kernel modules
# Must be regenerated after kernel changes - the scripts are patched when generating the EFI.
initrd() {
  buildah copy initos-builder rootfs/sbin /sbin

  buildah run -v ${WORK}:/data \
    -v ${WORK}/boot:/boot \
    -v ${WORK}/lib/modules:/lib/modules \
    -v ${WORK}/lib/firmware:/lib/firmware \
    initos-builder \
      setup-initos setup_initrd
}

# Build the initos alpine rootfs.
sidecar() {
  _build_cmd alpine:edge initos-sidecar  setup-sidecar install
  
  # Build the SQFS.
  updateAlpine
}


# Can run commands with 'buildah run kernel' - this updates the sqfs.
updateDeb() {
  rm -rf ${WORK}/efi/initos*
  _run_cmd kernel setup-initos sqfs /data/efi/initos
  #"$@"
}

updateAlpine() {
  rm -rf ${WORK}/efi/sidecar*
  _run_cmd initos-sidecar setup-initos sqfs /data/efi/initos sidecar
  #"$@"
}

# Experimental targets

dockerb() {
   docker build --network host --target kernel  . -t costinm/initos-rootfs
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


