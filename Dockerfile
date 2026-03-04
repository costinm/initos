# syntax=docker/dockerfile:1.10

# Sidecar container
# DOCKER_BUILDKIT=1 podman build --target sidecar -t sidecar .
# podman build --output DIR --target out .

ARG ALPINE_BASE=alpine:edge


#################
FROM debian:trixie-slim AS deb-base

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

COPY ./bin/setup-deb /opt/initos/bin
RUN --mount=target=/var/cache/apk,id=apk,type=cache \
  --mount=type=cache,target=/var/lib/apt/lists,id=aptlist \
  --mount=target=/var/cache/apt/archives,id=varcache,type=cache \
  /opt/initos/bin/setup-deb base

COPY  ./etc ./root /
COPY ./bin /opt/initos/bin

#################
# Dev tools - no UI or systemd
FROM deb-base AS deb-code


RUN --mount=type=cache,target=/var/lib/apt/lists,id=aptlist \
  --mount=target=/var/cache/apt/archives,id=varcache,type=cache \
  /opt/initos/bin/setup-deb dev


#################
# UI - no coding tools.
FROM deb-base AS deb-ui

RUN --mount=type=cache,target=/var/lib/apt/lists,id=aptlist \
  --mount=target=/var/cache/apt/archives,id=varcache,type=cache \
  /opt/initos/bin/setup-deb ui

#################
# Dev tools + UI + systemd.
FROM deb-code AS deb-codeui

RUN --mount=type=cache,target=/var/lib/apt/lists,id=aptlist \
  --mount=target=/var/cache/apt/archives,id=varcache,type=cache \
  ls -l /var/cache/apt/archives && \
  /opt/initos/bin/setup-deb ui


#################
FROM ${ALPINE_BASE} AS sidecar-base

COPY ./bin/setup-sidecar /bin/setup-sidecar
RUN --mount=target=/var/cache/apk,id=apk,type=cache \
  ls -l /var/cache/apk && \
  setup-sidecar min && \
  setup-sidecar alpine_add_virt 


#################

FROM sidecar-base AS alpine-dev


COPY ./bin/setup-sidecar /bin/setup-sidecar
RUN --mount=target=/var/cache/apk,id=apk,type=cache \
  setup-sidecar add_dev
COPY ./ /

#################

FROM alpine-dev AS alpine-ui

RUN --mount=target=/var/lib/cache,id=apt,type=cache \
  --mount=target=/var/cache,id=varcache,type=cache \
  setup-sidecar add_wui


