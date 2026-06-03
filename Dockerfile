# syntax=docker/dockerfile:1.10

# Sidecar container
# DOCKER_BUILDKIT=1 podman build --target sidecar -t sidecar .
# podman build --output DIR --target out .

ARG BASE=debian:trixie-slim
ARG NAME=deb-host
# By default use the function installing packages for kernel build
ARG SCRIPT=kernel_build_tools

#################
FROM ${BASE} AS sidecar

ARG SCRIPT
COPY ./sidecar/bin/setup-deb /opt/initos/bin/setup-deb

RUN --mount=type=cache,target=/var/lib/apt/lists,id=aptlist \
  --mount=target=/var/cache/apt/archives,id=varcache,type=cache \
  \
  rm -f /etc/apt/apt.conf.d/docker-clean; \
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache; \
  /opt/initos/bin/setup-deb ${SCRIPT}

COPY ./sidecar/bin /opt/initos/bin
RUN mkdir -p /x /c /z

#################
### Building the rust apps with rust-builder - test for deps.
FROM rust:latest AS rust-builder

RUN apt-get update && apt-get install -y musl-tools
RUN rustup target add x86_64-unknown-linux-musl
RUN rustup target add x86_64-unknown-uefi
WORKDIR /ws/initos
COPY . .
RUN cargo build --release --target x86_64-unknown-linux-musl --bin initos
RUN cargo build --release --target x86_64-unknown-uefi --bin efi

### Package a docker image containing efi
FROM scratch AS efi
COPY --from=rust-builder /ws/initos/target/x86_64-unknown-uefi/release/efi.efi /

### Disks Builder - prepares the artifacts for initos and boot images
FROM sidecar AS disks-builder
#RUN apt-get update && apt-get install -y erofs-utils cpio gzip findutils gawk curl coreutils xxd
WORKDIR /ws/initos
COPY . .
COPY --from=rust-builder /ws/initos/target/x86_64-unknown-linux-musl/release/initos /ws/initos/target/x86_64-unknown-linux-musl/release/initos
COPY --from=rust-builder /ws/initos/target/x86_64-unknown-uefi/release/efi.efi /ws/initos/target/x86_64-unknown-uefi/release/efi.efi
RUN ./scripts/build.sh build_initos
RUN ./scripts/build.sh build_boot

### Package a docker image containing disks/initos
FROM scratch AS disks-initos
COPY --from=disks-builder /ws/initos/target/disks/initos /
