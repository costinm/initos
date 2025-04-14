#!/bin/sh

# Example custom build, with additional features.
#
# This will build an EFI image for a 'dev machine' with 
# chromium, code-oss, labwc or sway UI. 
# 
# debkernel and initos_base should be built first (build.sh base).
# (images are tagged with local names by the builder - it is possible to 
# also pull a prebuilt image and tag)

POD=initosdev

SRCDIR=$(pwd)
. ${SRCDIR}/env

mkdir -p ${WORK}/lib_cache ${WORK}/apkcache 
VOLS="$VOLS -v ${WORK}/lib_cache:/var/lib/cache"
VOLS="$VOLS -v ${WORK}/apkcache:/etc/apk/cache"
VOLS="$VOLS -v ${WORK}:/data"

# Call build kernel and build base first

buildah rm ${POD}
buildah --name ${POD} from --pull=never initos-base

# Patch the alpine rootfs container to add UI.
# The script has few functions that can be called post-install.
buildah run ${VOLS} ${POD}  /sbin/setup-recovery wui

buildah run ${VOLS} ${POD} apk add git code-oss chromium \
   git bash bash-completion \
   kubectl k3s

# k3s removes crun and adds runc (not using docker)
# Podman can also use runc.

# Save lib modules, boot to the $WORK directory from the kernel image.
# This can be the basic debian kernel or the full rootfs including nvidia
# driver. Will be used to create the SQFS and initrd
buildah copy kernel rootfs/sbin /sbin
buildah run ${VOLS} kernel /sbin/setup-initos save_lib

# Re-generate sqfs and initrd. Will use the debkernel images
# for modules
${SRCDIR}/rootfs/sbin/setup-builder updatesqfs

#${SRCDIR}/sign.sh


