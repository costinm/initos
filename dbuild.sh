#!/bin/sh

# InitOS is based on OCI images - this builds the image using 
# a 'light' Dockerfile, using scripts for most operations.

# The result is 2 images - a 'recovery' image and 'full'. The full includes
# firmware, kernel and modules.

export SRCDIR=${SRCDIR:-$(pwd)}
export REPO=${REPO:-git.h.webinf.info/costin}

export DOCKER_BUILDKIT=1

set -e

# Build the recovery docker images.
all() {
  docker build --progress plain  \
     -t ${REPO}/initos-recovery:latest --target recovery \
     -f ${SRCDIR}/Dockerfile ${SRCDIR}

  docker build --progress plain  \
     -t ${REPO}/initos-full:latest --target full \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}
  
}

deb() {
  debhost
  debui
}

debhost() {
  docker build --progress plain  \
     -t ${REPO}/initos-debhost:latest --target debhost \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}
}

debui() {
  docker build --progress plain  \
     -t ${REPO}/initos-debui:latest --target debui \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}
}

push() {
  docker push ${REPO}/initos-recovery:latest
  docker push ${REPO}/initos-full:latest
}

dist() {
  docker build --progress plain  \
     -t ${REPO}/initos-recovery-dists:latest --target out \
     -o ${OUT} \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}
}

# If not args - run all and push
if [ $# -eq 0 ]; then
  all
  push
else 
  $*
fi
