#!/bin/bash

# Wrapper around /sbin/setup-builder script which is included in the image.
# Can build the local 'base' images (debian kernel and InitOS base) or 
# all, including the final EFI disk builder (slow).

SRCDIR=$(dirname "$(readlink -f "$0")")
. ${SRCDIR}/env

export POD=initos
# Output generated here
export WORK=${HOME}/.cache/${POD}

# Rebuild the builder image.
# It cleans and get current kernel and alpine.
all() {
  ${SRCDIR}/rootfs/sbin/setup-builder all "$@"
}

# Build the base image (if making changes to packages or configs)
base() {
  ${SRCDIR}/rootfs/sbin/setup-builder initos_base "$@"
}

# kernel (less frequently)
kernel() {
  ${SRCDIR}/rootfs/sbin/setup-builder debkernel "$@"
}

# Initos Alpine based Builder and base rootfs (in future signer will be separate)
# No longer includes the .sqfs - created from a sepearate rootfs image 
builderO() {
  # TODO: change back to adding the modules to base, no sqfs or initrd.
  # The sign script can do this on first run and cache.
  # The image is larger (as .tar) - but easier to make updates and caching is
  # better.
  ${SRCDIR}/rootfs/sbin/setup-builder initos_efi_builder "$@"
}

# Build the SQFS and initrd. Sign needs to be called for final EFI and signing
# The pod can be updated as needed.
build() {
  ${SRCDIR}/rootfs/sbin/setup-builder updatesqfs "$@" 
}

updateO() {
  rm -rf ${WORK}/efi/*
  ${SRCDIR}/rootfs/sbin/setup-builder update /data/efi/initos
  #"$@"
}

# Experimental targets

# debsqfs1() {
#   local KIMG=${1:-kernel}
#   buildah copy initos-base rootfs/sbin /sbin

#   buildah run  \
#     -v ${WORK}:/data \
#          --mount=type=bind,from=${KIMG},src=/,dst=/mnt/img initos-base \
#      /sbin/setup-initos sqfs_img 
# }

# Full build for the debian kernel and rootfs.
debrootfs() {
  ${SRCDIR}/rootfs/sbin/setup-builder _build_cmd debian:bookworm-slim kernel \
      /sbin/setup-initos debian_rootfs
}

# Just update the sqfs image, after adding packages or making changes to 
# kernel. Building the kernel/nvidia/etc is very slow.
debsqfs() {
  local KIMG=${1:-kernel}
  
  buildah copy kernel rootfs/sbin /sbin

  buildah run  \
    -v ${WORK}:/data kernel \
     /sbin/setup-initos sqfs
}

initrd() {
  buildah run -v ${WORK}:/data \
    -v ${WORK}/boot:/boot \
    -v ${WORK}/lib/modules:/lib/modules \
    -v ${WORK}/lib/firmware:/lib/firmware \
    initos-base bash
    #setup-initos build_initrd
}

initrdo() {
  buildah run -v ${WORK}:/data \
    initos setup-initos build_initrd
}

signer() {
  local KIMG=${1:-kernel}
  buildah copy initos-base rootfs/sbin /sbin

  buildah run  \
    -v ${WORK}:/data  initos-base \
     /sbin/setup-initos signer 
}

if [ -z "${1+x}" ] ; then
  echo "Building the images for InitOS kernel, root and EFI builder"
  echo
  echo " all - clean build of all 3"
  echo
  echo " kernel - latest debian kernel (kernel)"
  echo " base - the Alpine rootfs base image (initos-base)"
  echo " builder - Combines base and kernel, this is the image used by sign script (${POD})"
  echo 
  echo " update - Updates the SQFS and initrd files if local changes are made"
  
else
  "$@"
fi


