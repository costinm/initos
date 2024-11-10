#!/bin/sh

# Experimental: building a 'distribution', consisting of the files that need
# to be added to a USB disk (unsigned).
# This is using a Dockerfile to build - not the recovery image directly.

export SRCDIR=${SRCDIR:-$(pwd)}
export OUT=${OUT:-/x/vol/initos}

export REPO=${REPO:-git.h.webinf.info/costin}

export DOCKER_BUILDKIT=1

# Build the recovery docker images.
all() {
  recovery
  build_dist
}

virt() {
  export DOCKER_BUILDKIT=1
  docker build --progress plain -o ${OUT} \
     -f ${SRCDIR}/tools/Dockerfile.vm ${SRCDIR}
}


# Build image - github action also builds the image.
recovery() {
  set -e
  docker build --progress plain  \
     -t ${REPO}/initos-recovery:latest --target recovery \
     -f ${SRCDIR}/Dockerfile ${SRCDIR}

  docker build --progress plain  \
     -t ${REPO}/initos-full:latest --target full \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}
}

build_dist() {
  docker build --progress plain  \
     -t ${REPO}/initos-recovery-dists:latest --target out \
      -o ${OUT} \
      -f ${SRCDIR}/Dockerfile ${SRCDIR}
}


docker_push() {
  docker push ${REPO}/initos-recovery:latest
  docker push ${REPO}/initos-full:latest
}

$*