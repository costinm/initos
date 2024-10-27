# syntax=docker/dockerfile:1.10


# Run with:
# docker build --progress plain . -o /x/vol/initos -f tools/Dockerfile.boot
#
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
  /sbin/setup-initos mod_sqfs
EOF

COPY ./recovery/sbin/ /sbin/
RUN <<EOF
  EFI_FILE=/boot/efi/EFI/BOOT/initos-alpine.efi /sbin/setup-initos efi
EOF



########  Build the deb EFI
FROM  ${REPO}/initos-recovery:latest as deb-efi

COPY --from=deb --link /lib/modules/ /lib/modules
COPY --from=deb --link /lib/firmware/ /lib/firmware
COPY --from=deb --link /boot/ /boot/

RUN  <<EOF
    mod_dir=$(ls /lib/modules)
    echo -n ${mod_dir} > /boot/version
    /sbin/setup-initos mod_sqfs
EOF

COPY --from=alpine-efi /boot/intel-ucode.img /boot/
COPY --from=alpine-efi /boot/amd-ucode.img /boot/

COPY ./recovery/sbin/ /sbin/
RUN  <<EOF
    EFI_FILE=/boot/efi/EFI/BOOT/initos-deb.efi /sbin/setup-initos efi
EOF


### USB installer image content
## Run docker build with -o DIR - the files with be saved.
FROM scratch as efi

COPY --link --from=deb-efi /boot/efi/ ./

COPY --link --from=alpine-efi /boot/efi/ ./
