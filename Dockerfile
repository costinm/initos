# syntax=docker/dockerfile:1.10

# DOCKER_BUILDKIT=1 docker build -t initos .
# About <500M

ARG BASE=alpine:edge
# Can be swapped with other images based on debian - including istio build-tools
# Will add UI, etc on top.
ARG DEBBASE=debian:bookworm-slim

#################
FROM ${BASE} as initos-base

# Rest of the files added in the last step (to avoid rebuilds)
COPY ./recovery/sbin/setup-recovery /sbin/setup-recovery

# Cache the APKs
RUN  --mount=target=/etc/apk/cache,id=apk,type=cache \
    /sbin/setup-recovery install 
    
COPY ./recovery/ /

######## Debian: kernel
FROM ${DEBBASE} as debkernel

COPY ./recovery/sbin/setup-initos /sbin/setup-initos
RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  setup-initos add_deb_kernel

#################
FROM initos-base as tmp

COPY --from=debkernel --link /lib/modules/ /lib/modules
COPY --from=debkernel --link /boot/ /boot/
COPY --from=debkernel --link /lib/firmware/ /lib/firmware

RUN /sbin/setup-initos build_initrd
RUN /sbin/setup-initos recovery_sqfs recovery /boot

#################
FROM initos-base as recovery

COPY --from=tmp --link /boot/ /boot/



#### SQFS generation - normally done using the image itself.
# Will also generate unsigned EFI for USB installer.
# Signing still requires running the container with the private keys mounted.
# FROM recovery as sqfs

# RUN  --mount=target=/etc/apk/cache,id=apk,type=cache \
#     /sbin/setup-initos recovery_sqfs

# FROM scratch as out
# COPY --link --from=sqfs /x/initos ./

