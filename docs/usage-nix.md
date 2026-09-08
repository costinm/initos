# Managing InitOS with Nix

These instructions are for a trusted build/sign machine that has Nix. 

We fetch the InitOS flake from GitHub, build the signer and the kernel artifacts locally, and retain the host-tool plus NVIDIA-compute closure for transfer to another Nix machine.

The signed boot artifacts are built and signed - ready to distribute. They can
also be produced by the protected GitHub Actions signing path described below.

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
and firmware EROFS images, their signatures, and
`boot-initos-signed.vfat`.

## GitHub signed rolling release

The `Nix Build` workflow signs at the end of its ordinary build job, reusing
the signer and kernel outputs already built by that job. Trusted signing runs
only for a `main` push when `INITOS_SIGNING_KEYS_B64` is available. Pull
requests and builds without that secret sign with the obviously insecure keys
under `prebuilt/testdata/uefi-keys`, so the complete signing and packaging path
is still tested; those outputs are workflow artifacts but are never published
as `signed-rolling`. Keep the real key as a repository or organization secret
available to this workflow; a protected GitHub Environment cannot be attached
to only the final steps of a job.

The secret is a base64-encoded gzip tar containing the existing contents of the
trusted signing directory:

```sh
tar -C "$HOME/.ssh/initos" -czf - \
  PK.crt PK.cer PK.esl PK.auth \
  KEK.crt KEK.cer KEK.esl KEK.auth \
  db.key db.crt db.cer db.esl db.auth \
  root.pem \
  | base64 -w0 \
  | gh secret set INITOS_SIGNING_KEYS_B64
```

GitHub secrets are limited to 48 KB. Check the encoded byte count before
uploading if extra material is added. The workflow refuses to generate missing
keys and publishes no private key files. Only `db.key`, which signs the EFI
loader, kernel, initrd, modules, firmware, and root image, is uploaded; keep the
PK, KEK, and mesh-root private keys offline. Protect `main` and require review
for workflow changes, because any trusted workflow with access to this secret
is part of the signing trust boundary.

The rolling release contains these stable signed assets when signing was
authorized:

```text
initos-signed-slot.tar.gz
initos-signed-firmware.tar.gz
SHA256SUMS
```

`initos-signed-slot.tar.gz` contains exactly the signed files installed into
`/z/img/101` or `/z/img/102`: `boot-initos-signed.vfat`, the InitOS image and
signatures, and the signed module EROFS images and signatures.
`initos-signed-firmware.tar.gz` separately contains the current shared
`/z/img/firmware.erofs`, the experimental `firmware-light.composefs`, its Nix
backing-directory pointer, and both sets of signatures. The composefs image
describes the same complete firmware tree as `firmware.erofs`, but stores only
metadata and content-addressed redirects. Its backing object directory is a
Nix output containing symlinks to the immutable firmware tree. It is not
selected by the boot path yet. There is intentionally no signed-artifact NAR:
the release does not transfer a Nix closure full of mostly unchanged inputs.

The full image is generated with nixpkgs-pinned `erofs-utils` and fixed build
time, ownership, UUID, path ordering, and worker count. The composefs metadata
uses a fixed epoch and worker count. This makes both metadata images
reproducible for identical input trees. Build the Nix-backed prototype with:

```sh
nix build ./linux#firmwareImagesLight --out-link /z/c/initos-firmware
```

`firmware-light.basedir` names that output's content-addressed object directory.
The kernel configuration already enables built-in EROFS, file-backed EROFS,
OverlayFS/metacopy, and fs-verity. A future boot-path experiment must verify the
signed composefs image and mount it with this `basedir` before it can replace
the current self-contained firmware image.

The `git-hashing` Nix feature supplies Git blob/tree content addresses, but by
itself it does not make an ordinary binary cache transfer changed files from a
monolithic Nix output. File-granular upgrades additionally require a
Git-object-capable source/store for the firmware tree (or finer Nix outputs).

## Publish and fetch the incremental firmware tree

`SIGN_HOST` is the build and firmware source machine; `SERVER_HOST` is a
separate server.
Both the server and UI NixOS configurations enable `git-hashing` and
`ca-derivations` and install Git, composefs, and fsverity-utils, but neither
configuration implicitly turns that machine into the firmware publisher.

The checked-in UI and server configurations are hostname-neutral templates.
Copy the appropriate one and let the target render `$INITOS_HOSTNAME` from its
current hostname, or pass the desired hostname explicitly:

```sh
scp nix/ui/etc/nixos/configuration.nix \
  "root@${UI_HOST}:/tmp/configuration.nix"
ssh "root@${UI_HOST}" \
  'initos-upgrade configure /tmp/configuration.nix'

scp nix/server/etc/nixos/configuration.nix \
  "root@${SERVER_HOST}:/tmp/configuration.nix"
ssh "root@${SERVER_HOST}" \
  "initos-upgrade configure /tmp/configuration.nix '${SERVER_HOST}'"
```

`configure` validates the hostname, retains the current file as a timestamped
`/etc/nixos/configuration.nix.before-initos-*` backup, installs the rendered
configuration, and runs `nixos-rebuild switch`.

Both configurations enable `initos-rc-local.service`. After local filesystems
are available, systemd checks for `/z/c/initos/rc.local` and, when present,
executes it with Bash. The file remains host-local and must provide any PATH or
other environment needed by its commands. Inspect failures with:

```sh
systemctl status initos-rc-local.service
journalctl -u initos-rc-local.service -b
```

On `SIGN_HOST`, publish a built firmware output into a persistent bare
repository:

```sh
firmware=$(nix build ./linux#firmware --no-link --print-out-paths)
revision=$(initos-upgrade firmware-publish \
  "$firmware" /z/img/git/initos-firmware.git)
```

If consumers can access `SIGN_HOST`, fetch a pinned commit and construct the
composefs object directory directly:

```sh
initos-upgrade firmware-fetch \
  "build@${SIGN_HOST}:/z/img/git/initos-firmware.git" \
  "$revision" /z/img/firmware-light.composefs /z/img/firmware-objects
```

Where SSH access intentionally runs only from `SIGN_HOST` to a consumer, push the
bare repository to that consumer and materialize from the local path instead:

```sh
ssh "root@${UI_HOST}" 'git init --bare --initial-branch=main /z/img/git/initos-firmware.git'
git --git-dir=/z/img/git/initos-firmware.git push \
  "root@${UI_HOST}:/z/img/git/initos-firmware.git" refs/heads/main
ssh "root@${UI_HOST}" initos-upgrade firmware-fetch \
  /z/img/git/initos-firmware.git "$revision" /z/img/firmware-light.composefs \
  /z/img/firmware-objects
```

Git transfers and retains objects, so later pushes reuse unchanged firmware
blobs. `firmware-fetch` streams each Git blob into the shared digest object
directory, enables fs-verity on new objects, and validates the directory
against the signed composefs metadata. The firmware contents therefore do not
need to be copied into `/nix/store`. `trusted-users = root costin system build`
on `SIGN_HOST` authorizes the local `build` account for privileged Nix operations,
but it does not grant SSH access.

## Import on the master and promote through canary

On the canary (or a trusted staging machine with access to its state
partition):

```sh
mkdir -p "$HOME/releases/initos"
initos-upgrade fetch costinm/initos signed-rolling "$HOME/releases/initos"
sudo initos-upgrade install "$HOME/releases/initos" /dev/nvme0n1 102 --write
```

The command verifies `SHA256SUMS`, stages both archives, preserves the prior
slot as `/z/img/102.previous` until the boot image write succeeds, and then
writes `boot-initos-signed.vfat` to partition 102. Boot the canary and validate
it before installing the inactive slot on the remaining machines. A leftover
`.previous` directory means an earlier upgrade did not complete and must be
reviewed before retrying.

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
