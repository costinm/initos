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
export SRCDIR=${SRCDIR:-$(pwd)}

# Cache for apk and deb files
export WORK=${WORK:-${HOME}/.cache/initos}

export SRCDIR=${SRCDIR:-$(pwd)}

export REPO=${REPO:-git.h.webinf.info/costin}

# For the docker build variant.
export DOCKER_BUILDKIT=1

set -e


# Buildah notes:
# It is not possible to do mknod on rootless - so inside the 
# container it won't be able to do debootstrap or similar. 
# So getting the kernel in a temp deb container.

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
  initos_base


#  # Alpinetools plus the kernel/modules/firmware to build the image
#  # Can also use mounts when running alpinetools.
  initos
}

clean() {
  buildah rm initos-base initos kernel || true
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
initos_base() {
  local POD=initos-base
  buildah rm ${POD} || true
  mkdir -p ${WORK}/apkcache
  VOLS="$VOLS -v ${WORK}/apkcache:/etc/apk/cache"

  buildah pull alpine:edge
  buildah --name ${POD} ${VOLS} from alpine:edge

  buildah copy ${POD} rootfs /

  buildah run ${POD} setup-recovery install

  # This line can be removed to exclude virtualization tools
  # and kernel.
  buildah run ${POD} setup-recovery alpine_add_virt
  buildah run ${POD} setup-recovery linux_alpine
  
  #buildah commit ${POD} ${REPO}/initos-base:latest
  buildah commit ${POD} initos-base
}

# Only the kernel and drivers (no nvidia - install on the partition)
# The recovery is based on musl/alpine to keep it small.
debkernel() {
  mkdir -p ${WORK}/lib_cache
  VOLS="$VOLS -v ${WORK}/lib_cache:/var/lib/cache"

  local POD=kernel 

  buildah rm ${POD} || true

  buildah pull debian:bookworm-slim
  buildah --name ${POD} ${VOLS} from debian:bookworm-slim
  buildah copy ${POD} rootfs/sbin /sbin
  buildah run ${POD} -- setup-initos add_deb_kernel

  buildah commit ${POD} kernel
}

initos() {
  local POD=initos

  buildah rm ${POD} || true
  buildah --name ${POD} from initos-base 
  # ${REPO}/initos-base:latest

  buildah copy ${POD} rootfs/sbin /sbin

  # This could be done in the container with debootstrap
  buildah copy --from kernel ${POD} /boot/ /boot/
  #buildah copy --from debkernel ${POD} /lib/modules/ /lib/modules/
  #buildah copy --from debkernel ${POD} /lib/firmware/ /lib/firmware/

  # Build roimage and verity signature, directly on the out img dir.
  #
  # Will create SQFS files for the EFI images - smaller than including
  # the files directly and easier to use.

  buildah run \
    --mount=type=bind,from=kernel,src=/lib/modules,dst=/lib/modules \
    --mount=type=bind,from=kernel,src=/lib/firmware,dst=/lib/firmware \
    ${POD} -- setup-initos recovery_sqfs recovery /boot

  buildah run \
    --mount=type=bind,from=kernel,src=/lib/modules,dst=/lib/modules \
    --mount=type=bind,from=kernel,src=/lib/firmware,dst=/lib/firmware \
    ${POD}  setup-initos build_initrd

  buildah commit ${POD} ${REPO}/initos:latest
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
  # docker build --progress plain  \
  #    -t ${REPO}/initos-base:latest --target initos-base \
  #     -f ${SRCDIR}/Dockerfile ${SRCDIR}

  docker build --progress plain  \
     -t ${REPO}/initos:latest  \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}

  # docker build --progress plain  \
  #    --target out \
  #     -o ${OUT} \
  #     -f ${SRCDIR}/Dockerfile ${SRCDIR}
}

dpush() {
  # docker push ${REPO}/initos-base:latest
  docker push ${REPO}/initos:latest
}

$*

