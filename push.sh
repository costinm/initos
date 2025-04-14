#!/bin/bash

# Push the image to machines
# 
# The docker builder will create the files for th efi partition content under 
# ~/.cache/initos (by default), including the signed UKI
# 
# Once created, the image can be written to a USB stick - or copied to 
# machines that already run InitOS. 
# in ~/.ssh/initos/env
# - define CANARY, USB to point to machines used for testing secure and insecure boot.

# TODO: push to multiple machines
# TODO: send hash, have the remote remove the files if not matching (to avoid
# sync issues), verify at the end.

SRCDIR=$(dirname "$(readlink -f "$0")")
. ${SRCDIR}/env

export SRCDIR=${SRCDIR:-$(pwd)}

# The name of the 'pod' where the image was built. 
# 'buildah run ${POD}' can be used to inspect the builder container.
# and it is run with ~/.cache/${POD} mounted as /data.
POD=${POD:-initos}

# The builder generates output to /data/efi, which is mapped to $WORK
# on the host
WORK=${HOME}/.cache/${POD}/efi


push() {
  host=${1:-${CANARY}}
  shift
  set -xe

  # Build the EFI for the host, including host-specific configs
  # This packages the configs to a CPIO and signs.
  # Should not be large, just signing keys and core configs
  ${SRCDIR}/sign.sh $host

  newh=$(cat ${WORK}/initos/initos.hash )

  mkdir -p ${WORK}/install
  echo ${host} > ${WORK}/install/hostname

  # Temp while testing, should go to .ssh/initos/hosts/NAME
  cp testdata/test_setup ${WORK}/install/autosetup.sh

  # TODO: this should go to the sidecar, should use the script
  # to mount the alternate partition
  ssh $host /sbin/setup-initos-host upgrade_start #${newh}
  
  # Ignore the timestamp, inplace because the EFI is small (default creates a copy)
  rsync -ruvz -I --inplace ${WORK}/  $host:/boot/b

  ssh $host cat /boot/b/initos/initos.hash
  
  ssh $host /sbin/setup-initos-host upgrade_end "$@"

  # TODO: sleep and check, set permanent boot order
  # using swapNext
}

if [ -z ${1+x} ] ; then
  push
else
  push "$@"
fi


