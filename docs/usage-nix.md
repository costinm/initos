# Managing InitOS with Nix

These instructions are for a trusted build/sign machine that has Nix. 

We fetch the InitOS flake from GitHub, build the signer and the kernel artifacts locally, and retain the host-tool plus NVIDIA-compute closure for transfer to another Nix machine.

The signed boot artifacts are built and signed - ready to distribute.

## Build the required outputs

```sh
initos=github:costinm/initos
linux="$initos?dir=linux"

# The kernel build also pulls its modules, firmware, and matched NVIDIA payload.
kernel=$(nix build --refresh --no-link --print-out-paths "$linux#kernel-host")

# Retained Nix output links: these are registered as GC roots. The host root
# includes SSH-mesh. CUDA llama.cpp is an optional `.#gpu` package for GPU hosts.
mkdir -p "$HOME/opt"
signer=$(nix build --refresh --out-link "$HOME/opt/initos-signer" "$initos#initos-signer" --print-out-paths)

host_with_nvidia=$(nix build --refresh --out-link "$HOME/opt/initos-host" "$initos#initos-host-with-nvidia" --print-out-paths)
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

# Post sign instructions

## Copy signed images to a boot slot

Initos consists of an EFI partition image (boot-initos-signed.vfat), with partition number 101, 102, ... and a set of files that need to be placed on a ext4 partition labeled STATE containing img/101, etc - the boot partition number is the 'slot' - allowing safe A/B upgrade. The boot process mounts the STATE partition to /z, mounts the verified erofs images
and unlocks a /z/c fscrypt directory containing homes, the real root, nix, etc.

Ensure the remote login account can write the selected slot directory (or
prepare it with `sudo install -d /z/img/$slot`). Then copy the signed images to each slot that should receive the update:

```sh
slot=101 # alternate with 102
ssh "$remote" "sudo install -d /z/img/$slot"
scp "$output_dir/img/"* "$remote:/z/img/$slot/"

disk=/dev/sda
ssh $remote dd if=/z/img/$slot/boot-initos-signed.vfat of=${disk}${slot}
```

## Fresh install

```sh
DISK=/dev/nvme0n1
suffix=p

sfdisk --label gpt "$DISK" <<EOF
label-id: gpt

partition-101 : size=64M, name="BOOT1", type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
partition-102 : size=64M, name="BOOT2", type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
partition-1   : size=+, name="STATE"
EOF


mkfs.ext4 -L STATE -O encrypt,verity ${DISK}${suffix}1

mkdir -p /mnt/STATE 
mount ${DISK}${suffix}1 /mnt/STATE

setup-initos-host init_c


```

To setup TPM:

```sh

pass=$(initos decrypt /mnt/STATE/initos/c.age )

echo -n $pass | initos seal --dev


```

# Additional packages

These are intentionally excluded from the normal host and signing closures.

```sh
# CUDA llama.cpp profile for GPU hosts.
# About 5 GB
llama=$(nix build --refresh --out-link "$HOME/opt/llama" --print-out-paths "$initos#gpu")

# `ssh://` can fail while copying a content-addressed output when the remote
# store does not implement `registerDrvOutput`.  Export/import transfers the
# same complete closure without that remote-store operation.
nix-store --export $(nix-store -qR "$llama") | ssh "$remote" 'nix-store --import'
ssh "$remote" \
  "sudo nix build --out-link /opt/llama '$llama'"


# VM kernel, launch scripts, and hypervisor tools for VM hosts.
# About 1.57 GB
nix build --refresh --out-link "$HOME/opt/initos-vm" "$initos#vm"
```
