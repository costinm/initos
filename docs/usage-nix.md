# Managing InitOS with Nix

These instructions are for a trusted build/sign machine that has Nix. 

They fetch the InitOS flake from GitHub, build the signer and the kernel artifacts locally, and retain the host-tool plus NVIDIA-compute closure for transfer to another Nix machine.

The signed artifacts are built and signed - ready to distribute.

## Build the required outputs

```sh
initos=github:costinm/initos
linux="$initos?dir=linux"

# The kernel build also pulls its modules, firmware, and matched NVIDIA payload.
kernel=$(nix build --refresh --no-link --print-out-paths "$linux#kernel-host")

# Retained Nix output links: these are registered as GC roots.
mkdir -p "$HOME/opt"
nix build --refresh --out-link "$HOME/opt/initos-signer" "$initos#initos-signer"
nix build --refresh --out-link "$HOME/opt/initos-host" "$initos#initos-host-with-nvidia"
signer="$HOME/opt/initos-signer"
host_with_nvidia="$HOME/opt/initos-host"
```

The signer and host links are Nix GC roots, so their complete closures are
retained. The kernel is intentionally built with `--no-link`; once signing has
produced ordinary files in `$output_dir`, its kernel, modules, and firmware can
be garbage-collected and rebuilt when needed.

## Create signed artifacts

Keep the keys only on this trusted machine. `db.key` and `db.crt` must be in
`~/.ssh/initos`; `image_key.pem` is created there if it is absent.

```sh
output_dir="$PWD/initos-signed"
mkdir -p "$output_dir"

SECRETS="$HOME/.ssh/initos" \
  "$signer/bin/sign.sh" artifacts "$output_dir" "$kernel/opt/kernel-image" "$signer"
```

The result is in `$output_dir/img`, including the signed kernel/initrd, module
and firmware EROFS images, their signatures, and `boot-initos.img`.

## Transfer host tools and NVIDIA compute to a Nix host

The remote machine must already run Nix and accept `ssh://` Nix-store access.

Copy the one root so Nix transfers its complete closure:

```sh
remote=host.example

nix copy --to "ssh://$remote" "$host_with_nvidia"
ssh "$remote" \
  "nix-store --add-root /nix/var/nix/gcroots/initos-host --indirect -r '$host_with_nvidia'"
```

## Copy signed images to a boot slot

Ensure the remote login account can write the selected slot directory (or
prepare it with `sudo install -d /z/img/$slot`). Then copy the signed images
to each slot that should receive the update:

```sh
slot=101 # alternate with 102
ssh "$remote" "sudo install -d /z/img/$slot"
scp "$output_dir/img/"* "$remote:/z/img/$slot/"

disk=/dev/sda
ssh $remote dd if=/z/img/$slot/boot-initos-signed.vfat of=${disk}${slot}
```
