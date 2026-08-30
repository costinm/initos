# Using InitOS

These instructions are for an operator outside the source tree. They require Docker or Podman.

```sh
image=ghcr.io/costinm/initos-signer:latest
docker pull "$image"
```

## Install the host package closure

The image includes `/result`: the basic host package set, Nix, and signing tools - but excluding kernel and kernel-dependent packages.

### Fresh host without `/nix`

Create the host `/nix` directory, mount only it at `/host/nix`, and initialize
it from `/result`. Run it only when `/nix` is empty.

```sh
sudo mkdir -p /nix
sudo docker run --rm \
  -v /nix:/host/nix \
  "$image" \
  init_nix
```

### Existing host Nix daemon

Mount only the daemon socket. This imports the `/result` closure if it is not
already present. The container prints the host-side GC-root and SSH-copy
commands instead of requiring a `/nix` bind mount.

```sh
sudo docker run --rm \
  -v /nix/var/nix/daemon-socket/socket:/run/host-nix-daemon.sock \
  "$image" \
  copy_nix
```

## Create signed artifacts

Keep signing keys on the trusted signing host. They are mounted read-only and
are never copied into the image or output directory.

```sh
output_dir="$PWD/initos-signed"
mkdir -p "$output_dir"

docker run --rm \
  -v "$HOME/.ssh/initos:/var/run/secrets/uefi-keys:ro" \
  -v "$output_dir:/out" \
  "$image" \
  artifacts /out
```

## Install signed images

Copy the generated files to /z/img/$SLOT (101 or 102) - this is what the kernel us using. The number should match the partition number used for boot - I'm using 101 and 102, but 
can be any partition number and as many as needed.

This copies `initos.erofs`, module/firmware EROFS files, signatures, and the boot VFAT image.


```sh
slot=101 # or 102
sudo install -d "/z/img/$slot"
sudo cp -a "$output_dir/img/." "/z/img/$slot/"
```

Deploy the VFAT image to the EFI boot partition separately if
your host boot layout requires it:

```sh
dd if=/z/img/$slot/boot-initos.img /dev/nvme0n1p${slot}
```
