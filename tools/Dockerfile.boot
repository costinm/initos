# syntax=docker/dockerfile:1.10


# Run with:
# docker build --progress plain . -o /x/vol/initos -f tools/Dockerfile.boot

# Download debian kernels in debian.
# Package them as UKI in the recovery image.
#
# Currently not using alpine kernels - using debian
# for the nvidia drivers and as a VM for building. Separate
# build for them to speed up.

ARG REPO=git.h.webinf.info/costin

######## Debian kernel and modules
FROM debian:bookworm as deb

RUN --mount=target=/var/lib/cache,id=apt,type=cache <<EOF
 echo deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware >> /etc/apt/sources.list

 apt update

 apt install -y --no-install-recommends firmware-linux-free \
   firmware-misc-nonfree \
   firmware-realtek \
   linux-image-amd64

EOF

FROM debian:bookworm as vdeb

RUN --mount=target=/var/lib/cache,id=apt,type=cache <<EOF
 echo deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware >> /etc/apt/sources.list

 apt update

 apt install -y --no-install-recommends \
   linux-image-cloud-amd64

EOF

######### Arch kernel and modules
#FROM arch:latest as arch
#
#RUN pacman -Syu linux linux-firmware


### Build the Alpine EFI
FROM  ${REPO}/initos-recovery:latest as alpine-efi

RUN --mount=target=/etc/apk/cache,id=apk,type=cache /sbin/setup-initos linux_alpine

RUN <<EOF
  /sbin/setup-initos recovery_sqfs
  /sbin/setup-initos firmware_sqfs
  #/sbin/setup-initos mods_sqfs
EOF

# COPY ./recovery/sbin/ /sbin/
# RUN <<EOF
#   EFI_FILE=/boot/efi/EFI/BOOT/initos-alpine.efi /sbin/setup-initos efi
# EOF


########  Build the deb EFI
FROM  ${REPO}/initos-recovery:latest as deb-efi

COPY --from=deb --link /lib/modules/ /lib/modules
COPY --from=deb --link /lib/firmware/ /lib/firmware
COPY --from=deb --link /boot/ /boot/

RUN  <<EOF
    mod_dir=$(ls /lib/modules)
    echo -n ${mod_dir} > /boot/version
    /sbin/setup-initos mods_sqfs
    # Using debian firmware (less options)
    #/sbin/setup-initos firmware_sqfs
EOF

COPY --from=alpine-efi /boot/intel-ucode.img /boot/
COPY --from=alpine-efi /boot/amd-ucode.img /boot/

COPY ./recovery/sbin/ /sbin/
RUN  <<EOF
    EFI_FILE=/boot/efi/EFI/BOOT/initos-deb.efi /sbin/setup-initos efi
EOF


########  Build the deb EFI virtual
FROM  ${REPO}/initos-recovery:latest as vdeb-efi

COPY --from=vdeb --link /lib/modules/ /lib/modules/
COPY --from=vdeb --link /boot/ /boot/

RUN  <<EOF
    mod_dir=$(ls /lib/modules)
    echo -n ${mod_dir} > /boot/version-virt
    /sbin/setup-initos mods_sqfs
EOF

COPY ./recovery/sbin/ /sbin/
RUN  /sbin/setup-initos vinit



### USB installer image content
## Run docker build with -o DIR - the files with be saved.
FROM scratch as efi

# Unsigned EFI files - signing and 'customization' is a separate step
# using the recovery docker image.
COPY --link --from=deb-efi /boot/ ./
COPY --link --from=vdeb-efi /boot/ ./
COPY --link --from=alpine-efi /boot/ ./

# Copy the kernel and initrd files, for signing and customization.
# We append a custom command line and initrd.
