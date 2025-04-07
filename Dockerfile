# syntax=docker/dockerfile:1.10

# DOCKER_BUILDKIT=1 docker build -t initos .
# About <500M

ARG BASE=alpine:edge
# Can be swapped with other images based on debian - including istio build-tools
# Will add UI, etc on top.
ARG DEBBASE=debian:bookworm-slim

#################
FROM ${BASE} as initos-base

# Required if base is setting a different user ( like sunshine )
# USER root
# ENV LANG C.UTF-8
# # Will create a base username
# ARG USERNAME=build
# # Istio base sets it to /home - need to copy or link the files
# ENV HOME /x/home/${USERNAME}
# ENV FONTCONFIG_PATH /etc/fonts
# ENV PATH /sbin:/usr/sbin:/bin:/usr/bin:/x/sync/app/bin:/x/sync/app/home/bin:/usr/local/bin:${PATH}
# WORKDIR /x/home/${USERNAME}
# # Not installing accessibility dbus
# ENV NO_AT_BRIDGE 1

# Rest of the files added in the last step (to avoid rebuilds)
COPY ./rootfs/sbin/setup-recovery /sbin/setup-recovery

# Cache the APKs
RUN  --mount=target=/etc/apk/cache,id=apk,type=cache \
    /sbin/setup-recovery install 
    
COPY ./rootfs /

######## Debian: kernel
FROM ${DEBBASE} as kernel

COPY ./rootfs/sbin/setup-initos /sbin/setup-initos

RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  setup-initos add_deb_kernel


######## TODO: Arch
# Arch 
#FROM arch:latest as kernel
#
#RUN pacman -Syu linux linux-firmware


### Generate the binary images - can be used with the basic recovery 
# to sign and generate the USB
FROM scratch as out
COPY --link --from=initos /boot ./

#################
FROM initos-base as tmp

COPY --from=kernel --link /lib/modules/ /lib/modules
COPY --from=kernel --link /boot/ /boot/
COPY --from=kernel --link /lib/firmware/ /lib/firmware

RUN /sbin/setup-initos build_initrd
RUN /sbin/setup-initos recovery_sqfs recovery /boot

#################
FROM initos-base as initos

COPY --from=tmp --link /boot/ /boot/
