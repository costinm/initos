# Building initos and container images

This document is for maintainers working from the initos source tree. Operators
who only have Docker or Podman should use [usage.md](usage.md); Nix-only
operators should use [usage-nix.md](usage-nix.md).

## Build outputs

The normal published image is `docker-image`, tagged
`initos-signer:latest` and published as `ghcr.io/costinm/initos-signer:latest`.
It is normally the only image pulled in practice: kernel, modules, firmware,
and NVIDIA compute dominate the payload, so splitting out host runtime saves
little for an operator.

| Nix output | Compressed archive | Contents |
| --- | ---: | --- |
| `docker-signer-tools-image` | 78 MB | signer script, unsigned `img/` inputs, signing tools; no kernel |
| `docker-kernel-artifacts-image` | rebuild required | kernel, modules, firmware, `sign-file`, matched NVIDIA compute |
| `docker-signer-kernel-image` | rebuild required | compatibility combination of signer tools and kernel artifacts |
| `docker-host-runtime-image` | rebuild required | `/result`: generic host tools, SSH-mesh, Nix, signing tools; no kernel/NVIDIA |
| `docker-image` | rebuild required | published workflow image: signer, kernel artifacts, and `/result` |
| `./linux#docker-image` | 1.52 GB | legacy kernel-artifacts image from the Linux subflake |

Archive sizes are measured compressed Docker tarballs. Rows marked `rebuild
required` changed after the previous measurement. The largest individual
objects are `initos-kernel-host` and `nvidia-x11`; see the current build report
or `nix path-info --json` for exact NAR sizes.

CUDA llama.cpp is deliberately separate because its closure is about 5.18 GiB
unpacked. Build it only on GPU hosts with `nix build .#gpu`.

## Build with Nix

```sh
# Normal published workflow image.
nix build .#docker-image --out-link /tmp/initos-signer.tar.gz

# Split images, useful for cache/layer inspection or separate publication.
nix build .#docker-signer-tools-image
nix build .#docker-kernel-artifacts-image
nix build .#docker-host-runtime-image
```

`dockerTools` emits gzip-compressed archives. Load a locally built archive with:

```sh
gzip -dc /tmp/initos-signer.tar.gz | docker load
```

## Nix profile workflow

NixOS is not required; Nix as a package manager is sufficient.

```sh
np() { nix profile "$@" --profile "${NIX_PROFILE:-target/nix/profiles}"; }

# First build may build the kernel.
np add ./linux#kernel-host
np add .#initos-signer

# Rebuild after source changes.
np upgrade linux
np upgrade initos
```

The signer can then create artifacts with its wrapped runtime tools:

```sh
./target/nix/profiles/bin/sign.sh artifacts /tmp/initos-signed
```

## Verify EROFS payloads

Maintainers should verify generated module EROFS images before calling a
build/deployment complete. Extract each image, require no symlinks, and reject
a `/nix/store` reference:

```sh
verify_erofs() {
  image="$1"
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' RETURN
  fsck.erofs --extract="$stage" "$image"
  test -z "$(find "$stage" -type l -print -quit)"
  ! grep -aFq /nix/store "$image"
  printf '%s: %s regular files\n' "$image" "$(find "$stage" -type f | wc -l)"
}

for image in /tmp/initos-signed/img/modules-*.erofs; do
  verify_erofs "$image"
done
```

For container-only signing, host-store installation, and deployment into
`/z/img/101` and `/z/img/102`, use [usage.md](usage.md).
