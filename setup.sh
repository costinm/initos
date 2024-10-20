#!/bin/sh

export SRCDIR=${SRCDIR:-$(pwd)}
export WORK=${WORK:-/x/initos}
export REPO=${REPO:-git.h.webinf.info/costin}

export IMAGE=${IMAGE:-${REPO}/initos-recovery:latest}
export CONTAINER=initos-recovery

# Will use a regular docker container named 'initos', running 'sleep'
# The 'sign' step uses a fresh ephemeral container and only signs.

# This is a wrapper around the container run with mounted default volumes,
# calling the setup-initos script.
# Everything except building the recovery image is done in the recovery container.
drun() {
  ${SRCDIR}/recovery/sbin/setup-in-docker drun /ws/initos/recovery/sbin/setup-initos $*
}

sh() {
  ${SRCDIR}/recovery/sbin/setup-in-docker drunit /bin/sh
}

# All builds an '[/x/initos]/boot/efi' dir ready to use with a USB disk or
# copied on a (large enough - at least 1G) EFI partition
all() {
  # Get kernel, modules, firmware - and create sqfs and populate /x/initos/boot
  drun sqfs

  recovery_sqfs
  efi
  sign
}

allvirt() {
  # Get kernel, modules, firmware - and create sqfs and populate /x/initos/boot
  drun vlinux_alpine
  recovery_sqfs
  drun vinit
}

# Create the recovery.sqfs file for USB and VM
recovery_sqfs_crane() {
  docker push ${REPO}/initos-recovery:latest

  drun recovery_sqfs_crane ${REPO}/initos-recovery:latest recovery
}

recovery_sqfs() {
  docker rm -f initos-tmp
  docker run --name initos-tmp ${IMAGE} echo

  mkdir -p ${WORK}/boot/efi
  rm -f ${WORK}/boot/efi/recovery.sqfs

  docker export initos-tmp | docker run -i \
    -v ${WORK}/boot/efi:/boot/efi \
    -v ${SRCDIR}:/ws/initos \
     --rm ${IMAGE} /sbin/setup-initos recovery_sqfs_docker_export

  docker stop initos-tmp
  docker rm initos-tmp
}

export_recovery() {
  if [ -f ${WORK}/recovery/bin/busybox ]; then
    sudo rm -rf /x/initos/recovery/*
  fi
  if [ ! -d ${WORK}/recovery ]; then
    btrfs subvolume create ${WORK}/recovery || mkdir -p ${WORK}/recovery
  fi
  docker export initos-recovery | sudo tar -C ${WORK}/recovery -xf -
}

# Generate recovery image as $REPO/initos-recovery:latest. Will not push.
# A container initos-recovery running the image will be left running (sleep).
# Will mount source dir and /x/vol/initos in the container.
recovery() {
  docker rm -f initos-recovery || true

  # Start a container based on alpine:edge, named initos-recovery
  ${SRCDIR}/recovery/sbin/setup-in-docker start alpine:edge initos-recovery

  # Exec the setup-initos script in the container - install_recovery will add all recovery
  # packages
  docker exec initos-recovery ${SRCDIR}/recovery/sbin/setup-initos install_recovery

  # Label the result - this is the recovery image.
  # It does not include /boot, modules or firmware - those are mounted from the host.
  docker commit initos-recovery ${REPO}/initos-recovery:latest

 # Equivalent:
 # For the recovery docker build.
 # All other steps are run in a container or chroot.
 #export DOCKER_BUILDKIT=1
 #  docker build --progress plain \
 #    -t ${REPO}/initos-recovery:latest -f ${SRCDIR}/Dockerfile ${SRCDIR}
  docker push ${REPO}/initos-recovery:latest
}



# Use the recovery image to build an UKI image. Will download the alpine
# kernel and modules on $WORK/modules volume if they don't exist.
#
# Signing may happen on a different machine with access to the private keys.
efi() {
  # This takes very long - only do it on a clean build
  # If starting from an Alpine installer, this will be there along with the kernel.
  if [ ! -f ${WORK}/boot/version ]; then
    drun linux_alpine
  fi

  drun efi
}

# Sign will sign the EFI files - using the keys in /etc/uefi-keys
# This is a separate step - not using the sleeping docker container/pod/etc - but
# a fresh container that only signs.
sign() {
  VOLS="-v ${WORK}/boot:/boot"
  VOLS="$VOLS -v ${SRCDIR}/recovery/sbin/setup-initos:/sbin/setup-initos"
  VOLS="$VOLS -v ${SRCDIR}/recovery/sbin/initos-secure:/sbin/initos-secure"
  VOLS="$VOLS -v ${SRCDIR}/recovery/sbin/initos-common.sh:/sbin/initos-common.sh"
  # /x will be the rootfs btrfs, with subvolumes for recovery, root, modules, etc
  VOLS="$VOLS -v ${WORK}:/x/initos"

  mkdir -p ${HOME}/.ssh/initos/uefi-keys
  # Inside the host or container - initos files will be under /initos (for now)
  docker run -it --rm \
      ${VOLS} \
      -v ${HOME}/.ssh/initos/uefi-keys:/etc/uefi-keys \
    ${REPO}/initos-recovery:latest /sbin/setup-initos sign
}


# If no parameters, print usage
if [ $# -eq 0 ]; then
  echo "Usage: $0 <command> <args>"
  echo "Commands:"
  echo "  all - run all steps, create a boot/efi directory with all the required files"
  echo
  echo "For development/making changes:"
  echo "   recovery - rebuild the recovery image from scratch after making changes"
  echo "   recovery_sqfs - rebuild the recovery.sqfs image on boot/efi"
  echo "   efi - create the UKI image (not signed)"
  echo "   sign - create the keys if missing and sign the UKI"

  exit 1
fi

$*
