#!/bin/sh

# This script will build 2 docker images:
# - alpinetools - alpine plus tools to build UKI and for recovery
# - initos - aplinetools plus pre-build initrd, kernel and sqfs image
#
# The SQFS image contains the latest debian modules, initrd contains
# the alpine-based initrd based on the same modules.
# All additional files are under /boot.
# 
# There are 2 variants, one using Dockerfile and one with buildah.
# 
# The 'setup.sh' script will use the initos image to create a 
# signed EFI kernel, and initialize the keys if missing.
# 
# You can use setup.sh without building the OCI image first - using
# the github-built images will be used instead. 

# Using /var/cache/build as top dir - must be owned by build
# ~/.local/share/containers point to the same place, ephemeral and can
# be cleaned

# Initos source dir - can be on the alpinetools image or on the source.
IDIR=/ws/initos/recovery/sbin
export SRCDIR=${SRCDIR:-$(pwd)}
# All created files, mounted to /x/initos in container
export WORK=${WORK:-/var/cache/build/initos}

# Container run - script to run a command in a container
# Current dir is /ws/initios, WORK dir is /x/initos

CRUN=${SRCDIR}/recovery/sbin/run-oci

export SRCDIR=${SRCDIR:-$(pwd)}
export REPO=${REPO:-git.h.webinf.info/costin}
export OUT=${OUT:-/x/vol/initos}

export DOCKER_BUILDKIT=1

set -e



# Buildah notes:
# It is not possible to do mknod on rootless - so inside the container it won't
# be able to do debootstrap or similar. So instead getting the kernel in a
# temp deb container.

all() {
  clean

  # Get the latest kernel.
  # When kernel changes, rebuild everything.
  debkernel

  # Tools to build initrd (and UKI, image, etc).
  # This must be alpine (or something with musl library) to keep initrd small.
  # mkinitrd works with debian - but would copy libc files.
  # Using the go/rust initrd may be better - but I think alpine and shell
  # is easier to read and understand.
  alpinetools


#  # Alpinetools plus the kernel/modules/firmware to build the image
#  # Can also use mounts when running alpinetools.
  recovery
}

clean() {
  buildah rm alpinetool recovery debkernel || true
  buildah rmi ${REPO}/initos-base:latest || true
  buildah rmi ${REPO}/initos:latest || true
  # rmi -a # all images
  rm -rf ${WORK}
}


# This is an alpine-based image with the tools for creating the signed
# UEFI UKI image. It needs the modules and firwmare from the debian host, since
# the kernel is debian (could be arch or something else - needs to
#  be compatible)
#
# The mkinitfs and other tools can also be ported to debian - WIP.
alpinetools() {
  local POD=alpinetools 
  buildah rm ${POD} || true
  mkdir -p ${WORK}/work/apkcache
  VOLS="$VOLS -v ${WORK}/work/apkcache:/etc/apk/cache"

  buildah --name ${POD} ${VOLS} from alpine:edge

  buildah copy ${POD} recovery/ /

  buildah run ${POD} setup-recovery install
  
  buildah commit ${POD} ${REPO}/initos-base:latest
}

# Only the kernel and drivers (no nvidia - install on the partition)
# The recovery is based on musl/alpine to keep it small.
debkernel() {
  mkdir -p ${WORK}/work/cache
  VOLS="$VOLS -v ${WORK}/work/cache:/var/lib/cache"

  local POD=debkernel 

  buildah rm ${POD} || true

  buildah --name ${POD} ${VOLS} from debian:bookworm-slim
  buildah copy ${POD} recovery/ /
  buildah run ${POD} -- setup-initos add_deb_kernel

  buildah commit debkernel debkernel
}

recovery() {
  local POD=recovery

  buildah rm ${POD} || true
  buildah --name ${POD} from ${REPO}/initos-base:latest

  # This could be done in the container with debootstrap
  buildah copy --from debkernel ${POD} /boot/ /boot/
  #buildah copy --from debkernel ${POD} /lib/modules/ /lib/modules/
  #buildah copy --from debkernel ${POD} /lib/firmware/ /lib/firmware/

  buildah run \
    --mount=type=bind,from=debkernel,src=/lib/modules,dst=/lib/modules \
    --mount=type=bind,from=debkernel,src=/lib/firmware,dst=/lib/firmware \
    -v ${WORK}:/x/initos \
    ${POD} -- setup-initos recovery_sqfs recovery /boot

  buildah run \
    --mount=type=bind,from=debkernel,src=/lib/modules,dst=/lib/modules \
    --mount=type=bind,from=debkernel,src=/lib/firmware,dst=/lib/firmware \
    ${POD}  setup-initos build_initrd

  buildah commit ${POD} ${REPO}/initos:latest
}

# Build roimage and verity signature, directly on the out img dir.
#
# Will create SQFS files for the EFI images.
# Reques sqfstar to be installed (but can be done with another container)
roimage() {
  local POD=recovery
  
  buildah copy ${POD} recovery/ /
  buildah run \
    --mount=type=bind,from=debkernel,src=/lib/modules,dst=/lib/modules \
    --mount=type=bind,from=debkernel,src=/lib/firmware,dst=/lib/firmware \
    -v ${WORK}:/x/initos \
    ${POD} -- setup-initos recovery_sqfs recovery /x/initos/img
}


# will create the images from the running containers.
commit() {
  # About 500MB
  buildah push ${REPO}/initos:latest
  

  # About 200MB
  buildah push ${REPO}/initos-base:latest
}

##### Dockerfile

# Build the initos docker image.
dall() {
  docker build --progress plain  \
     -t ${REPO}/initos-base:latest --target initos-base \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}

  docker build --progress plain  \
     -t ${REPO}/initos:latest --target recovery \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}

  # docker build --progress plain  \
  #    --target out \
  #     -o ${OUT} \
  #     -f ${SRCDIR}/Dockerfile ${SRCDIR}
}

dpush() {
  docker push ${REPO}/initos-base:latest
  docker push ${REPO}/initos:latest
}

$*

