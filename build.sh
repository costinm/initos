#!/bin/sh

# WIP: use dbuild.sh (docker-based build) to build the docker images
# and dist images.
# 
# This script will use buildah(-style) script to do the build.
# Syntax and model is buildah, but it can also use docker and in 
# future kubectl and VM.
# 
# Like the Dockerfile, it creates a few containers:
# - debhost: debian with kernel, firmware, modules, host tools
# - recovery: alpine image with recovery tools
# - debui: debian with KasmVnc, I3 - no kernel (for containers)
# 
# Also, experimental and for low-end machines:
# - ahost: extends recovery using debian kernel, firmware, modules  
# - aui: ahost + Sway ( may fold into alpinehost)
#
# The 'setup.sh' script is using the recovery container:
#
# - generate signed UKI EFI files, which  will unlock the
#   TPM and run a rootfs (debhost or alpinehost)
# 
# - generates 'usb' unsigned UKI EFI, with shell access.
# It will boot unsigned rootfs (alpineui or debhost)
# 
# - img/ - sqfs images build from different containers.

export SRCDIR=${SRCDIR:-$(pwd)}

export OUT=${OUT:-/x/vol/initos/buildah}

export REPO=${REPO:-git.h.webinf.info/costin}

CRUN=${SRCDIR}/recovery/sbin/run-oci

export WORK=$HOME/tmp/initos
mkdir -p $WORK

all() {

  debhost
  debui
  recovery
  alpinehost
}

clear() {
  buildah rm debhost debui recovery alpinehost
}

# Debian with everything for a host - including virtual kernel
# and modules
debhost() {
  POD=debhost ${CRUN} from debian:bookworm-slim
  
  ${CRUN} run debhost ${IDIR}/setup-deb stage add_base_users 
  ${CRUN} run debhost ${IDIR}/setup-deb stage add_tools 
  ${CRUN} run debhost ${IDIR}/setup-deb stage add_kernel

  ${CRUN} run debhost ${IDIR}/setup-deb stage add_vkernel
  
}

# will create the images from the running containers.
commit() {
  # Host images (large)
  # 1.8GB (uncompressed)
  ${CRUN} commit debhost ${REPO}/debhost:latest
  # 1.2GB - without sway, 400M squash
  ${CRUN} commit alpinehost ${REPO}/alpinehost:latest
  
  # Containers (small-ish)
  # About 800MB
  ${CRUN} commit debui ${REPO}/debui:latest

  # About 200MB
  ${CRUN} commit recovery ${REPO}/recovery:latest
}

pushimg() {
  #buildah push ${REPO}/recovery:latest oci:-

  buildah unshare -m A=alpinehost -- \
   sh -c 'tar -cf - -C ${A} .' | \
    sqfstar ${WORK}/img/alpinehost.sqfs -e .dockerenv

}

IDIR=/ws/initos/recovery/sbin


debui() {
  POD=debui ${CRUN} from debian:bookworm-slim
  
  ${CRUN} run debui ${IDIR}/setup-deb stage add_base_users 
  ${CRUN} run debui ${IDIR}/setup-deb stage add_tools 

  ${CRUN} run debui ${IDIR}/setup-deb stage add_kasm
}


# Generate recovery image as $REPO/initos-recovery:latest. Will not push.
# A container initos-recovery running the image will be left running (sleep).
# Will mount source dir and /x/vol/initos in the container.
recovery() {
  POD=recovery ${CRUN} from alpine:edge
  ${CRUN} run recovery ${IDIR}/setup-alpine install

  ${CRUN} copy recovery recovery/ /
}

upgrade() {
  ${CRUN} run debhost apt-update 
  ${CRUN} run debhost dist-upgrade -y 
}

extract() {
  docker export debvm | \
    (cd /x/vol/devvm-v/rootfs-ro/ && sudo tar -xf  - )
}

sh() {
  ${CRUN} sh $*
}

alpinehost() {
  ${CRUN} commit recovery alpinehost
  POD=alpinehost ${CRUN} from alpinehost

  ${CRUN} copy --from debhost alpinehost  /boot/ /boot/
  ${CRUN} copy --from debhost alpinehost /lib/modules/ /lib/modules/
  ${CRUN} copy --from debhost alpinehost /lib/firmware/ /lib/firmware/
}

dist() {
  ${CRUN} run alpinehost ${IDIR}/setup-initos dist
}

sign() {
  VOLS="-v ${HOME}/.ssh/initos/uefi-keys:/etc/uefi-keys" ${CRUN} run alpinehost ${IDIR}/setup-initos sign
}

$*