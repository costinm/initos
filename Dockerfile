# syntax=docker/dockerfile:1.10

ARG BASE=alpine:edge
# Can be swapped with other images based on debian - including istio build-tools
# Will add UI, etc on top.
ARG DEBBASE=debian:bookworm-slim

######## Debian: kernel, modules, host rootfs, remote UI rootfs
FROM ${DEBBASE} as debbase

# Required if base is setting a different user ( like sunshine )
USER root
ENV LANG C.UTF-8
# Will create a base username
ARG USERNAME=build
# Istio base sets it to /home - need to copy or link the files
ENV HOME /x/home/${USERNAME}
ENV FONTCONFIG_PATH /etc/fonts
ENV PATH /sbin:/usr/sbin:/bin:/usr/bin:/x/sync/app/bin:/x/sync/app/home/bin:/usr/local/bin:${PATH}
WORKDIR /x/home/${USERNAME}
# Not installing accessibility dbus
ENV NO_AT_BRIDGE 1

COPY ./recovery/sbin/setup-deb /sbin/setup-deb

RUN --mount=target=/var/lib/cache,id=apt,type=cache <<EOF
  setup-deb stage add_base_users
  setup-deb stage add_tools
EOF

########  Download debian kernels and modules
FROM debbase as debhost

RUN --mount=target=/var/lib/cache,id=apt,type=cache <<EOF
  setup-deb stage add_kernel
EOF

######## For the cloud kernel.
FROM debian:bookworm-slim as vdeb

COPY ./recovery/sbin/setup-deb /sbin/setup-deb

RUN --mount=target=/var/lib/cache,id=apt,type=cache <<EOF
  setup-deb stage add_vkernel
EOF


######## Create a dev debian image with remote UI (kasmVNC)
FROM debbase as debui
COPY ./recovery/sbin/setup-deb /sbin/setup-deb

RUN --mount=target=/var/lib/cache,id=apt,type=cache <<EOF
  /sbin/setup-deb stage add_kasm
  #/sbin/setup-deb add_chrome
EOF

# Default is set for running in K8S / CloudRun / etc.
# Will detect if running as non-root.
ENTRYPOINT ["/sbin/init-pod"]
CMD ["pod"]

######## TODO: Arch
# Arch 
#FROM arch:latest as arch
#
#RUN pacman -Syu linux linux-firmware

######## Alpine firmware.
# No longer used - debian firmware is smaller and less complete, but 
# too complex to deal with the mix and get nvidia working.
# 
# It also downloads the alpine kernel/modules
# FROM  recoverybase as alpine-firmware

# RUN --mount=target=/etc/apk/cache,id=apk,type=cache <<EOF
#   /sbin/setup-alpine linux_alpine
# EOF

######## This is the real recovery - with the additional scripts.
#### recoverybase contains all the utils needed for creating EFI and running
# a ssh server. 
# Because firmware/modules are pretty large - it also adds few % with podman
# and a hypervisor. 
FROM ${BASE} as recoverybase

# Required if base is setting a different user ( like sunshine )
USER root
ENV LANG C.UTF-8
ENV PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/initos/bin

# Rest of the files added in the last step (to avoid rebuilds)
COPY ./recovery/sbin/setup-alpine /sbin/setup-alpine

# Cache the APKs
RUN  --mount=target=/etc/apk/cache,id=apk,type=cache \
    /sbin/setup-alpine install
################
# Used for building the initrd
FROM recoverybase as recovery

# Rest of the files
COPY ./recovery/ /

################
# Same as setup.sh script - less caching.
FROM full as out

RUN <<EOF
  setup-initos dist
EOF

### Generate the binary images - can be used with the basic recovery 
# to sign and generate the USB
FROM scratch as out
COPY --link --from=setup-out /x/initos ./

########  Build the full image - can directly sign and generate usb, 
# includes the VM kernel/initrd as well (42M).
# About 1.3G firmware, 400M modules, 50M boot - total 2G
# the alpine binaries are about 180M.

FROM recovery as full
# Modules and kernel from debian - includes the Alpine-based initrd
COPY --from=debhost --link /lib/modules/ /lib/modules
COPY --from=debhost --link /boot/ /boot/
COPY --from=debhost --link /lib/firmware/ /lib/firmware
COPY --from=vdeb --link /lib/modules/ /lib/modules/
COPY --from=vdeb --link /boot/ /boot/

# Firmware from Alpine (may switch to debian smaller set - testing it for now)
#COPY --from=alpine-firmware --link /lib/firmware/ /lib/firmware
#COPY --from=alpine-firmware /boot/intel-ucode.img /boot/
#COPY --from=alpine-firmware /boot/amd-ucode.img /boot/

