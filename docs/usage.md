# Using initos

initos builds a signing container and a nix package containing an unsigned
kernel, modules, EFI stub and initrd. It is **not** a USB installer — it is a
tool to sign and package those artifacts with **your own keys**, producing
images ready to deploy on target machines.

The docker image and nix kernel package are rebuilt weekly by a GitHub Actions
scheduled workflow and pushed to the rolling release:

- **Container**: `ghcr.io/costinm/initos-signer:latest`
- **Release assets**: <https://github.com/costinm/initos/releases/tag/rolling-release>
  - `initos-kernel-host.nar` — Nix store archive (CI build cache, ~1.8 GB)
  - `initos-kernel-host.tar.gz` — Kernel tarball for manual inspection
  - `initos-signer.tar.gz` — Signer scripts + initrd/EFI artifacts

---

## Option 1: Container (docker / podman)

On the trusted signing machine, mount a secrets directory and an output
directory into the container.  The first run generates keys under `SECRETS`
(default `/var/run/secrets/uefi-keys`).

```sh
# Pull the latest weekly build
docker pull ghcr.io/costinm/initos-signer:latest

# Run - keys are created on first run, reused on subsequent runs
docker run --rm \
  -v $HOME/.ssh/initos:/var/run/secrets/uefi-keys \
  -v /tmp/out:/out \
  ghcr.io/costinm/initos-signer:latest \
  artifacts /out

# Image is rebuilt weekly; discard and re-pull to get updates
docker rmi ghcr.io/costinm/initos-signer:latest
```

The container bundles the kernel, modules and unsigned initrd/EFI artifacts
and all signing tools.  `artifacts` signs everything with the db key and
writes the output to `/out`.

---

## Option 2: Nix profile (no docker required)

Requires Nix (as a package manager; NixOS is not required).

### 2a. From the rolling-release NAR (binary, no build)

```sh
# Import the kernel + modules into the local nix store (~1.8 GB)
nix-store --import < <(curl -fL \
  https://github.com/costinm/initos/releases/download/rolling-release/initos-kernel-host.nar)

# Build the signer from source (fast — kernel is already in the store)
# or wait for a pre-built signer to be published
nix profile add --profile ./target/nix/profiles \
  github:costinm/initos#initos-signer \
  github:costinm/initos/linux#kernel-host
```

### 2b. From git source

```sh
np() { nix profile "$@" --profile "${NIX_PROFILE:-target/nix/profiles}"; }

# First time (slow — builds kernel)
np add ./linux#kernel-host
np add .#initos-signer

# On changes
np upgrade linux
np upgrade initos
```

### Generate signed images

```sh
# Keys are generated in SECRETS on first run (default: /var/run/secrets/uefi-keys)
# sign.sh has all runtime tools pre-wired in its PATH via nix

rm -rf /tmp/outi
./target/nix/profiles/bin/sign.sh artifacts /tmp/outi
```

---

## Deploying to a machine

```sh
HOST=host17

# Copy signed module/firmware images to the STATE partition
rsync -avu /tmp/outi/img/ $HOST:/z/img/

# Flash the EFI boot partition (A or B)
cat /tmp/outi/img/boot-initos-signed.vfat | ssh $HOST dd of=/dev/nvme0n1p102
```

---

## Generated artifacts

`sign.sh artifacts <output_dir>` produces:

- **Keys** (first run only) — PK, KEK, db UEFI Secure Boot keys and an Ed25519
  image-signing key, stored in `SECRETS` (default `$HOME/.ssh/initos`).
- **`kernel/bzImage`** — kernel copied from the signing container / nix profile.
- **`img/initos.erofs` + `.sig`** — fs-verity signed initrd EROFS image.
- **`img/modules-<version>.erofs` + `.sig`** — kernel modules re-signed with
  db.key and packed into a signed EROFS image.
- **`img/firmware.erofs`** — firmware image (unsigned, verified by path).
- **`img/boot-initos-signed.vfat`** — 32 MB VFAT EFI boot partition containing
  the signed kernel, initrd, EFI stub and boot config.

The `.vfat` images go to the target machine's GPT `BOOTA`/`BOOTB` EFI
partitions.  The `.erofs` images go under `/img/` on the `STATE` partition.

---

## First install

TODO