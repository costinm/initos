# syntax=docker/dockerfile:1.10

# DOCKER_BUILDKIT=1 docker build --target sidecar -t sidecar .

# DOCKER_BUILDKIT=1 docker build --target modloop -t modloop .

# DOCKER_BUILDKIT=1 docker build --target initos-sidecar .


ARG BASE=alpine:edge
# Can be swapped with other images based on debian - including istio build-tools
# Will add UI, etc on top.
ARG DEBBASE=debian:bookworm-slim


######## Debian: kernel extracted as modloop
FROM ${DEBBASE} as modloop

COPY ./rootfs/sbin /sbin

# Should create files under "/data/boot" - container just installs stuff,
# but we are not using the rest so no point to upload the container.
RUN \
  --mount=target=/var/lib/cache,id=apt,type=cache \
     setup-deb modloop && ls -l /data/boot


######## TODO: Arch
# Arch 
#FROM arch:latest as kernel
#
#RUN pacman -Syu linux linux-firmware



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

FROM ${BASE} as signer
COPY ./sidecar /
RUN setup-sidecar add_builder

#################


FROM ${BASE} as sidecar-base

COPY ./sidecar /
RUN \
  setup-sidecar min && \
  setup-sidecar alpine_add_virt && \
  setup-sidecar add_builder
#################


#################

FROM sidecar-base as alpine-dev

RUN setup-sidecar add_dev

#################

FROM alpine-dev as alpine-ui

RUN setup-sidecar add_wui


#################
FROM sidecar as tmp-gen

RUN /sbin/setup-initos sqfs /data/efi/initos sidecar
RUN /sbin/setup-efi unsigned

#################

### Generate the binary images - can be used with the basic recovery 
# to sign and generate the USB
# 
# Use: podman build --target efi . --output DEST_DIR
FROM scratch as efi
COPY --from=tmp-gen /data/efi ./


#################
FROM sidecar-base as sidecar

COPY --from=modloop /boot /boot
COPY --from=modloop /lib/modules /lib/modules
COPY --from=modloop /lib/firmware /lib/firmware

RUN /sbin/setup-initos build_initrd
COPY prebuilt/linux.efi.stub /boot/

#################
