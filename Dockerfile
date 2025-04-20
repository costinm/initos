# syntax=docker/dockerfile:1.10

# DOCKER_BUILDKIT=1 docker build -t initos .
# About <500M

ARG BASE=alpine:edge
# Can be swapped with other images based on debian - including istio build-tools
# Will add UI, etc on top.
ARG DEBBASE=debian:bookworm-slim


FROM ${BASE} as data

RUN mkdir /data

######## Debian: kernel
FROM ${DEBBASE} as kernel

COPY ./rootfs/sbin /sbin

RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  --mount=target=/data,from=data,rw \
   setup-initos debian_rootfs_base


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
#FROM ${BASE} as builder

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
#COPY ./rootfs /

# Cache the APKs
# RUN  --mount=target=/etc/apk/cache,id=apk,type=cache \
#     /sbin/setup-efi install 
    

#################
# FROM initos-builder as tmp

# COPY --from=kernel --link /lib/modules/ /lib/modules
# COPY --from=kernel --link /boot/ /boot/
# COPY --from=kernel --link /lib/firmware/ /lib/firmware

# RUN /sbin/setup-initos build_initrd
# RUN /sbin/setup-initos recovery_sqfs recovery /boot

#################
FROM ${BASE} as sidecar

COPY ./rootfs /
COPY ./sidecar /
RUN setup-sidecar install

