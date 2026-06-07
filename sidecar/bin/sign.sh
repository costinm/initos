#!/usr/bin/env bash
#
# sign.sh 
#  - Use or create signing keys in ${SECRETS:-/var/run/secrets/uefi-keys}
#  - Sign and package .vfat EFI partitions signed with the user specific keys
#  - sign .erofs files - initos second stage, modules, firmware
#
# This script provides reusable functions for:
#   - Checking prerequisites (openssl, fsverity, mkfs.erofs)
#   - Generating Ed25519 keypairs
#   - Signing digests
#   - Creating signed images with fs-verity
#   - Generating EFI signing keys
#   - Generating boot configs and sigining EFI.
#
# Usage (function dispatch):
#   setup_signed.sh sign_init
#   setup_signed.sh artifacts <output_dir> [kernel-dir] [artifacts-dir]

set -euo pipefail
PATH="/usr/sbin:/sbin:${PATH}"

SECRETS=${SECRETS:-/var/run/secrets/uefi-keys}

# --- Key generation ---

# Generate the key pairs for signing the kernel and the disk image.
# This is done before install - as a separate step/process - the rest can be automated easily,
# but signing must be done on a secure machine and is specific to each user.
sign_init() {
    local u=${DOMAIN:-mesh.internal}

    mkdir -p "${SECRETS}"

    if [ -f "${SECRETS}/root.key" ] ; then
        echo "Keys already exist"
        return 0
    fi
    # Alpine only
    #efi-mkkeys -s ${u} -o ${SECRETS}
    
    # Debian - sbsigntool, efitools, openssl
    local cert_to_siglist="cert-to-siglist"
    if ! command -v cert-to-siglist >/dev/null 2>&1 && command -v cert-to-efi-sig-list >/dev/null 2>&1; then
        cert_to_siglist="cert-to-efi-sig-list"
    fi

    (
        cd "${SECRETS}"

        openssl req -new -x509 -newkey rsa:2048 \
            -nodes -days 3650 \
            -subj "/CN=pk.efi/" \
            -keyout PK.key -out PK.crt 

        ${cert_to_siglist} PK.crt PK.esl 
        sign-efi-sig-list -k PK.key -c PK.crt PK PK.esl PK.auth
        
        openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=kek.efi/" \
            -keyout KEK.key -out KEK.crt

        ${cert_to_siglist} KEK.crt KEK.esl
        sign-efi-sig-list -k PK.key -c PK.crt KEK KEK.esl KEK.auth

        openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=db.efi/" \
            -keyout db.key -out db.crt    
        ${cert_to_siglist} db.crt db.esl
        sign-efi-sig-list -k KEK.key -c KEK.crt db db.esl db.auth
    )

    # Generate a 'mesh root' - both SSH and https.  
    # Will be bundled on all signed images, and used to encrypt the LUKS pass.
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out ${SECRETS}/root.key

    openssl ec -in ${SECRETS}/root.key -pubout -out \
        ${SECRETS}/root.pem
    
    ssh-keygen -y -f ${SECRETS}/root.key > ${SECRETS}/authorized_keys

    # SSL and SSH key is the real public - minisign is using the sha.

    minisign -GW -s ${SECRETS}/minisign.key -p ${SECRETS}/minisign.pub
    PUB=$(sed -n '2p' ${SECRETS}/minisign.pub)

    echo $PUB
    #cat ${SECRETS}/minisign.pub

    cat ${SECRETS}/authorized_keys

    echo "Generating Ed25519 keypair..."
    openssl genpkey -algorithm ed25519 -out "${SECRETS}/image_key.pem" 2>/dev/null
    openssl pkey -in "${SECRETS}/image_key.pem" -pubout -out "${SECRETS}/image_key_pub.pem" 2>/dev/null

    # Extract raw 32-byte public key (last 32 bytes of DER encoding) as base64
    local pub_key_b64
    pub_key_b64=$(openssl pkey -in "${SECRETS}/image_key.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
    echo -n "${pub_key_b64}" > "${SECRETS}/image_key.pub.b64"

    # Extract raw 32-byte private key seed (last 32 bytes of DER private key)
    # This is the Ed25519 seed, compatible with wireguard/libsodium raw key format
    openssl pkey -in "${SECRETS}/image_key.pem" -outform DER 2>/dev/null | tail -c 32 > "${SECRETS}/image_key.raw"

    echo "  Private key: ${SECRETS}/image_key.pem"
    echo "  Raw privkey: ${SECRETS}/image_key.raw (32 bytes)"
    echo "  Public key:  ${SECRETS}/image_key_pub.pem"
    echo "  Pub base64:  ${pub_key_b64}"
}

# Sign a binary digest file with an Ed25519 private key.
# Usage: sign_digest <digest_file> <private_key_pem> <output_sig>
# This is used for the STATE erofs disk.
sign_digest() {
    local digest_file="${1:?Usage: sign_digest <digest_file> <private_key_pem> <output_sig>}"
    local private_key="${2:?Usage: sign_digest <digest_file> <private_key_pem> <output_sig>}"
    local output_sig="${3:?Usage: sign_digest <digest_file> <private_key_pem> <output_sig>}"

    echo "Signing digest..."
    openssl pkeyutl -sign -rawin \
        -inkey "${private_key}" \
        -in "${digest_file}" \
        -out "${output_sig}" 2>/dev/null

    echo "  Signature: ${output_sig} ($(wc -c < "${output_sig}") bytes)"
}

# Sign a hex digest string (converts to binary, then signs).
# Usage: sign_hex_digest <hex_digest> <private_key_pem> <output_sig>
sign_hex_digest() {
    local hex_digest="${1:?Usage: sign_hex_digest <hex_digest> <private_key_pem> <output_sig>}"
    local private_key="${2}"
    local output_sig="${3}"

    local tmpbin
    tmpbin=$(mktemp)
    echo -n "${hex_digest}" | xxd -r -p > "${tmpbin}"
    
    sign_digest "${tmpbin}" "${private_key}" "${output_sig}"
    rm -f "${tmpbin}"
}

# --- Full pipeline ---



# Sign artifacts without natively enabling fs-verity (computes digest offline).
# Usage: image <image_dir> <file_name>
image() {
    local image_dir="${1:?Usage: create_signed_offline <image_path> <output_dir>}"
    local filen="${2:?Usage: create_signed_offline <image_path> <output_dir>}"
    
    local img_name
    img_name="${image_dir}/${filen}"

    # Generate keypair if not already created, 
    # Using SECRETS env
    sign_init "${SECRETS:-${out}/test/secrets}"

    # Compute the fsverity digest offline (does not require root/mounting)
    local digest_hex
    digest_hex=$(fsverity digest "${img_name}" | awk '{print $1}' | sed 's/^sha256://')
    local digest_bin
    digest_bin="$(mktemp)"
    echo -n "${digest_hex}" | xxd -r -p > "${digest_bin}"

    # Sign the digest
    sign_digest "${digest_bin}" \
      "${SECRETS}/image_key.pem" \
      "${img_name}.sig"
    rm -f "${digest_bin}"
}

# Sign the boot EFI - original limine required embedding the SHA
# of the config, and the initrd/kernel into config.
# 
# EFI loader verifies config/initrd signatures using certs from the db variable.
# The EFI binary itself is signed with db.key for Secure Boot verification.
efi() {
    # HOME/.ssh/
    local sec_dir=${1:?Usage: efi <sec_dir>}
    local boot=${2:?Usage: efi <sec_dir> <boot_dir>}
    local signed="${boot}/EFI/BOOT/BOOTX64.EFI.signed"

    mkdir -p "${boot}/EFI/BOOT"
    
    PUB_KEY_B64=$(cat "${sec_dir}/image_key.pub.b64")

    echo "Signing BOOTX64.EFI..."

    sbsign --key "${sec_dir}/db.key" \
           --cert "${sec_dir}/db.crt" \
           --output  "${signed}" \
           "${boot}/EFI/BOOT/BOOTX64.EFI"
    mv "${signed}" "${boot}/EFI/BOOT/BOOTX64.EFI"

    if [ -f "${boot}/EFI/BOOT/initos.EFI" ]; then
        echo "Signing initos.EFI..."
        sbsign --key "${sec_dir}/db.key" \
               --cert "${sec_dir}/db.crt" \
               --output "${boot}/EFI/BOOT/initos.EFI.signed" \
               "${boot}/EFI/BOOT/initos.EFI"
        mv "${boot}/EFI/BOOT/initos.EFI.signed" "${boot}/EFI/BOOT/initos.EFI"
    fi

    ESP_DIR=${boot}

    KEY_ID=$(openssl x509 -in "${sec_dir}/db.crt" -pubkey -noout | openssl rsa -pubin -outform DER 2>/dev/null | openssl dgst -sha256 | sed 's/.*= //' | cut -c 1-16)

    SIG_FILE="$ESP_DIR/EFI/BOOT/${KEY_ID}.sig"
    echo "Signing config with db.key... (KEY_ID: ${KEY_ID})"
    
    openssl dgst -sha256 \
       -sign ${sec_dir}/db.key \
       -out "$SIG_FILE" \
       "$ESP_DIR/EFI/BOOT/config"

    # Create a signature for the kernel file using db.key (RSA)
    KERNEL_SIG_FILE="$ESP_DIR/EFI/BOOT/${KEY_ID}.kernel.sig"
    echo "Signing kernel with db.key..."
    openssl dgst -sha256 -sign ${sec_dir}/db.key \
       -out "$KERNEL_SIG_FILE" "$ESP_DIR/EFI/BOOT/bzImage"

    # # Create a signature for the initrd file using db.key (RSA)
    INITRD_SIG_FILE="$ESP_DIR/EFI/BOOT/${KEY_ID}.initrd.sig"
    echo "Signing initrd with db.key..."
    openssl dgst -sha256 -sign ${sec_dir}/db.key \
       -out "$INITRD_SIG_FILE" "$ESP_DIR/EFI/BOOT/initrd.img"
}

_build_fat_image() {
    local boot_path="${1:?Usage: _build_fat_image <boot_path> <img_file>}"
    local img_file="${2:?Usage: _build_fat_image <boot_path> <img_file>}"

    # Ensure absolute paths for operations since we perform 'cd'
    mkdir -p "${boot_path}"
    boot_path=$(cd "${boot_path}" && pwd)
    mkdir -p "$(dirname "${img_file}")"
    img_file=$(cd "$(dirname "${img_file}")" && pwd)/$(basename "${img_file}")

    local dir_size_kb img_size_mb
    dir_size_kb=$(du -sk "${boot_path}" | cut -f1)
    img_size_mb=$(( (dir_size_kb * 12 / 10 / 1024) + 1 ))
    [ "${img_size_mb}" -lt 64 ] && img_size_mb=64

    mkdir -p "$(dirname "${img_file}")"
    dd if=/dev/zero of="${img_file}" bs=1M count="${img_size_mb}" status=none
    mformat -i "${img_file}" -F -v "INITOSBOOT" ::
    (cd "${boot_path}" && mcopy -i "${img_file}" -s ./* ::)

    echo "  Created: ${img_file} ($(du -h "${img_file}" | cut -f1))"
}

# Sign a Nix artifact tree produced by .#initos-signer.
# Usage: artifacts [artifact_dir] <output_dir> [secrets_dir]
# If artifact_dir is omitted, it is auto-detected from the script's location.
artifacts() {
    local output_dir="${1:?Usage: artifacts <output_dir> [kernel_dir] [artifact_dir]}"
    mkdir -p "${output_dir}/img"
    output_dir=$(cd "${output_dir}" && pwd)

    local kernel_dir="${2:-}"
    local artifact_dir="${3:-}"
    local sec_dir="${SECRETS:-/var/run/secrets/uefi-keys}"

    # Auto-detect kernel_dir
    if [ -z "${kernel_dir}" ]; then
        local SCRIPT_DIR
        SCRIPT_DIR=$(dirname "$0")
        if [ "$SCRIPT_DIR" = "." ] && command -v "$0" >/dev/null 2>&1; then
            SCRIPT_DIR=$(dirname "$(command -v "$0")")
        fi
        
        local PROFILE_DIR
        PROFILE_DIR=$(dirname "$SCRIPT_DIR")
        
        if [ -f "/opt/kernel-image/bzImage" ]; then
            # Nix
            kernel_dir="/opt/kernel-image"
        elif [ -f "${PROFILE_DIR}/opt/kernel-image/bzImage" ]; then
            # Nix profile (e.g., .../result/opt/kernel-image/)
            kernel_dir="$(cd "${PROFILE_DIR}/opt/kernel-image" && pwd)"
        elif [ -f "/mnt/kernel-image/opt/kernel-image/bzImage" ]; then
            # Mounted from a docker image
            kernel_dir="/mnt/kernel-image/opt/kernel-image"
        elif [ -f "${PWD}/target/opt/kernel-image/bzImage" ]; then
            # In source tree
            kernel_dir="${PWD}/target/opt/kernel-image"
        fi
    fi

    # Require kernel artifacts
    if [ -z "${kernel_dir}" ] || [ ! -f "${kernel_dir}/bzImage" ]; then
        echo "ERROR: Kernel artifacts not found. Please provide kernel_dir with bzImage." >&2
        exit 1
    fi

    # Auto-detect alrtifact_dir
    if [ -z "${artifact_dir}" ]; then
        if [ -f "/img/initos.erofs" ]; then
            artifact_dir="/"
        elif [ -f "${PWD}/target/artifacts/img/initos.erofs" ]; then
            artifact_dir="${PWD}/target/artifacts"
        fi
    fi

    if [ -z "${artifact_dir}" ] || [ ! -f "${artifact_dir}/img/initos.erofs" ]; then
        echo "ERROR: initos artifacts not found. Please provide artifact_dir." >&2
        exit 1
    fi

    sign_init

    # Copy initos.erofs to output
    cp "${artifact_dir}/img/initos.erofs" "${output_dir}/img/"
    chmod u+w "${output_dir}/img/initos.erofs"
    image "${output_dir}/img" "initos.erofs"

    # Copy modules and firmware from kernel_dir to output
    for m in "${kernel_dir}"/modules-*.erofs; do
        [ -f "$m" ] && cp "$m" "${output_dir}/img/"
    done
    if [ -f "${kernel_dir}/firmware.erofs" ]; then
        cp "${kernel_dir}/firmware.erofs" "${output_dir}/img/"
    fi

    # Sign modules and firmware images if they exist
    for m in "${output_dir}"/img/modules-*.erofs; do
        if [ -f "$m" ]; then
            image "${output_dir}/img" "$(basename "$m")"
        fi
    done
    if [ -f "${output_dir}/img/firmware.erofs" ]; then
        image "${output_dir}/img" "firmware.erofs"
    fi

    # Create a temporary staging area for the boot files
    local boot_stage
    boot_stage=$(mktemp -d)
    mkdir -p "${boot_stage}/EFI/BOOT"

    # Copy from artifact_dir
    if [ -d "${artifact_dir}/boot" ]; then
        cp -R "${artifact_dir}/boot/." "${boot_stage}/"
    else
        cp -R "${artifact_dir}/." "${boot_stage}/"
    fi
    chmod -R u+w "${boot_stage}"

    # Resolve and copy kernel bzImage
    if [ -f "${kernel_dir}/bzImage" ]; then
        cp "${kernel_dir}/bzImage" "${boot_stage}/EFI/BOOT/bzImage"
    fi

    # Inject public key into config if present
    if [ -f "${sec_dir}/image_key.pub.b64" ] &&
       [ -f "${boot_stage}/EFI/BOOT/config" ] &&
       ! grep -q 'INITOS_PUB_KEY=' "${boot_stage}/EFI/BOOT/config"; then
        printf ' INITOS_PUB_KEY=%s\n' "$(cat "${sec_dir}/image_key.pub.b64")"           >> "${boot_stage}/EFI/BOOT/config"
    fi

    # Build the three boot variants from the staging area
    build_boot_limine_unsigned "${boot_stage}" "${output_dir}"
    build_boot_initos_signed "${boot_stage}" "${output_dir}" "${sec_dir}"
    build_boot_limine_signed "${boot_stage}" "${output_dir}" "${sec_dir}"

    rm -rf "${boot_stage}"
}

# Similar - but using limine as main loader.
sign_limine() {
    SHA_KERNEL=$(cat ${boot}/EFI/BOOT/bzImage | b2sum)
    SHA_INITRD=$(cat ${boot}/EFI/BOOT/initrd.img | b2sum)
   echo <<EOF > ${boot}/EFI/BOOT/limine.conf
timeout: 0
serial: yes
graphics: no
verbose: yes
editor_enabled: no

/BootA
  protocol: linux
  path: boot():/EFI/LINUX/bzImage#${SHA_KERNEL}
  cmdline: rdinit=/sbin/initos-initrd net.ifnames=0 panic=5 
  module_path: boot():/EFI/LINUX/initrd.img#${SHA_INITRD}  
EOF

  CFGSHA=$(cat ${boot}/EFI/BOOT/limine.conf |b2sum)

  cp ${boot}/EFI/BOOT/BOOTX64.EFI /tmp/limine.EFI
  limine enroll-config /tmp/limine.EFI $CFGSHA
  
  sbsign --cert /etc/uefi-keys/db.crt \
      --key /etc/uefi-keys/db.key \
      --output ${boot}/EFI/BOOT/limine.EFI \
       /tmp/limine.EFI 

  rm /tmp/limine.EFI
}

build_dmverity_boot() {
    ROOTFS_IMG="${out}/disks/state/img/initos.erofs"
    INITOS_IMG="${out}/test/initos.dmverity"

    echo "Generating ${INITOS_IMG} with appended dm-verity..."
    cp "${ROOTFS_IMG}" "${INITOS_IMG}"
    
    HASH_OFFSET=$(stat -c %s "${INITOS_IMG}")
    
    VERITY_OUT=$(veritysetup format --hash-offset=$HASH_OFFSET "${INITOS_IMG}" "${INITOS_IMG}")
    
    ROOT_HASH=$(echo "$VERITY_OUT" | awk '/Root hash:/ {print $3}')
    SALT=$(echo "$VERITY_OUT" | awk '/Salt:/ {print $2}')
    DATA_BLOCKS=$(echo "$VERITY_OUT" | awk '/Data blocks:/ {print $3}')
    
    echo "ROOT_HASH=$ROOT_HASH" > "${out}/initos.verity.txt"
    echo "SALT=$SALT" >> "${out}/initos.verity.txt"
    echo "HASH_OFFSET=$HASH_OFFSET" >> "${out}/initos.verity.txt"
    echo "DATA_BLOCKS=$DATA_BLOCKS" >> "${out}/initos.verity.txt"

    BOOT_DISK_DIR="${out}/disks/boot"
    mkdir -p "${BOOT_DISK_DIR}/EFI/BOOT"
    
    # KERNEL_SHA=$(sha256sum "${BOOT_DISK_DIR}/EFI/BOOT/bzImage" | awk '{print $1}')
    
    LENGTH=$((DATA_BLOCKS * 8))
    HASH_START_BLOCK=$(( (HASH_OFFSET / 4096) + 1 ))
    
    DM_STR="vroot,,,ro,0 ${LENGTH} verity 1 /dev/vdb /dev/vdb 4096 4096 ${DATA_BLOCKS} ${HASH_START_BLOCK} sha256 ${ROOT_HASH} ${SALT}"
    
    cat > "${BOOT_DISK_DIR}/EFI/BOOT/config.verity" <<EOF
root=/dev/dm-0 rootwait rootfstype=erofs dm-mod.create="${DM_STR}" dm-mod.waitfor=/dev/vdb
EOF
}

_resolve_path() {
    local dir="${1}"
    local rel_path="${2}"
    if [ -f "${dir}/${rel_path}" ]; then
        echo "${dir}/${rel_path}"
    elif [ -f "${dir}/boot/${rel_path}" ]; then
        echo "${dir}/boot/${rel_path}"
    elif [ -f "${dir}/disks/boot/${rel_path}" ]; then
        echo "${dir}/disks/boot/${rel_path}"
    else
        local base_dir
        base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        if [ -f "${base_dir}/${rel_path}" ]; then
            echo "${base_dir}/${rel_path}"
        elif [ "$(basename "${rel_path}")" = "bzImage" ] && [ -f "${base_dir}/target/linux/arch/x86/boot/bzImage" ]; then
            echo "${base_dir}/target/linux/arch/x86/boot/bzImage"
        elif [ "$(basename "${rel_path}")" = "bzImage" ] && [ -f "${base_dir}/target/linux/arch/x86_64/boot/bzImage" ]; then
            echo "${base_dir}/target/linux/arch/x86_64/boot/bzImage"
        elif [ "$(basename "${rel_path}")" = "bzImage" ] && [ -f "${base_dir}/target/img/bzImage" ]; then
            echo "${base_dir}/target/img/bzImage"
        elif [ -f "${base_dir}/prebuilt/${rel_path}" ]; then
            echo "${base_dir}/prebuilt/${rel_path}"
        else
            echo ""
        fi
    fi
}

_safe_cp() {
    local src_file="${1}"
    local dest_file="${2}"
    if [ -n "$src_file" ] && [ -f "$src_file" ]; then
        local real_src real_dest
        real_src=$(realpath "$src_file" 2>/dev/null || echo "$src_file")
        real_dest=$(realpath "$dest_file" 2>/dev/null || echo "$dest_file")
        if [ "$real_src" != "$real_dest" ]; then
            mkdir -p "$(dirname "$dest_file")"
            cp "$src_file" "$dest_file"
        fi
    fi
}

_copy_uefi_public_keys() {
    local src_dir="${1}"
    local dst_dir="${2}"

    if [ -n "${NIX_BUILD_TOP:-}" ]; then
        echo "Nix build environment detected — skipping public keys installation for unsigned package."
        return 0
    fi

    echo "Installing UEFI public keys into ${dst_dir}..."
    mkdir -p "${dst_dir}"
    for f in PK.crt PK.esl PK.auth KEK.crt KEK.esl KEK.auth db.crt db.esl db.auth authorized_keys image_key_pub.pem image_key.pub.b64 root.pem minisign.pub; do
        if [ -f "${src_dir}/${f}" ]; then
            cp "${src_dir}/${f}" "${dst_dir}/"
        fi
    done
}


build_boot_limine_unsigned() {
    local artifact_dir="${1:?Usage: build_boot_limine_unsigned <artifact_dir> <output_dir>}"
    local output_dir="${2:?Usage: build_boot_limine_unsigned <artifact_dir> <output_dir>}"
    local boot_path=$(mktemp -d)
    echo "=== Building limine-unsigned boot ==="

    mkdir -p "${boot_path}/EFI/BOOT"

    local bzimage_src initrd_src bootx64_src limine_conf_src initos_efi_src config_src
    bzimage_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/bzImage")
    initrd_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initrd.img")
    bootx64_src=$(_resolve_path "$artifact_dir" "boot/EFI/BOOT/BOOTX64.EFI")
    [ -z "$bootx64_src" ] && bootx64_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/BOOTX64.EFI")
    limine_conf_src=$(_resolve_path "$artifact_dir" "boot/EFI/BOOT/limine.conf")
    [ -z "$limine_conf_src" ] && limine_conf_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/limine.conf")
    initos_efi_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initos.EFI")
    [ -z "$initos_efi_src" ] && initos_efi_src=$(_resolve_path "$artifact_dir" "target/x86_64-unknown-uefi/release/efi.efi")
    config_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/config")
    [ -z "$config_src" ] && config_src=$(_resolve_path "$artifact_dir" "config")

    _safe_cp "$bzimage_src" "${boot_path}/EFI/BOOT/bzImage"
    _safe_cp "$initrd_src" "${boot_path}/EFI/BOOT/initrd.img"
    _safe_cp "$bootx64_src" "${boot_path}/EFI/BOOT/BOOTX64.EFI"
    _safe_cp "$limine_conf_src" "${boot_path}/EFI/BOOT/limine.conf"
    _safe_cp "$initos_efi_src" "${boot_path}/EFI/BOOT/initos.EFI"
    _safe_cp "$config_src" "${boot_path}/EFI/BOOT/config"

    local keys_src=$(_resolve_path "$artifact_dir" "keys/PK.crt")
    if [ -n "$keys_src" ] && [ "$(dirname "$(realpath "$keys_src" 2>/dev/null || echo "$keys_src")")" != "$(realpath "${boot_path}/keys" 2>/dev/null || echo "${boot_path}/keys")" ]; then
        _copy_uefi_public_keys "$(dirname "$keys_src")" "${boot_path}/keys"
    else
        local base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        if [ -d "${base_dir}/prebuilt/testdata/uefi-keys" ]; then
            _copy_uefi_public_keys "${base_dir}/prebuilt/testdata/uefi-keys" "${boot_path}/keys"
        fi
    fi

    mkdir -p "${output_dir}/img"
    _build_fat_image "${boot_path}" "${output_dir}/img/boot-limine-unsigned.vfat"
    rm -rf "${boot_path}"
}

build_boot_limine_signed() {
    local artifact_dir="${1:?Usage: build_boot_limine_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local output_dir="${2:?Usage: build_boot_limine_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local sec_dir="${3:-${SECRETS:-/var/run/secrets/uefi-keys}}"
    local boot_path=$(mktemp -d)
    echo "=== Building limine-signed boot ==="

    mkdir -p "${boot_path}/EFI/BOOT"

    local bzimage_src initrd_src bootx64_src config_src
    bzimage_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/bzImage")
    initrd_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initrd.img")
    bootx64_src=$(_resolve_path "$artifact_dir" "boot/EFI/BOOT/BOOTX64.EFI")
    [ -z "$bootx64_src" ] && bootx64_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/BOOTX64.EFI")
    config_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/config")
    [ -z "$config_src" ] && config_src=$(_resolve_path "$artifact_dir" "config")

    _safe_cp "$bzimage_src" "${boot_path}/EFI/BOOT/bzImage"
    _safe_cp "$initrd_src" "${boot_path}/EFI/BOOT/initrd.img"
    
    if [ -n "$config_src" ] && [ -f "$config_src" ]; then
        _safe_cp "$config_src" "${boot_path}/EFI/BOOT/config"
    else
        cat > "${boot_path}/EFI/BOOT/config" <<EOF
INITOS_INIT=/opt/initos/bin/initos-init-dev console=tty1 loglevel=6 net.ifnames=0 panic=5
EOF
    fi

    local sha_kernel sha_initrd
    sha_kernel=$(b2sum "${boot_path}/EFI/BOOT/bzImage" | awk '{print $1}')
    sha_initrd=$(b2sum "${boot_path}/EFI/BOOT/initrd.img" | awk '{print $1}')

    local cmdline="${INITOS_CMDLINE:-INITOS_INIT=/opt/initos/bin/initos-init-dev console=ttyS0,115200 console=tty1 net.ifnames=0 panic=5 loglevel=6}"
    cat > "${boot_path}/EFI/BOOT/limine.conf" <<LIMINECFG
timeout: 2
serial: yes
graphics: no
verbose: yes
editor_enabled: no

/Boot
  protocol: linux
  path: boot():/EFI/BOOT/bzImage#${sha_kernel}
  cmdline: ${cmdline}
  module_path: boot():/EFI/BOOT/initrd.img#${sha_initrd}
LIMINECFG

    local cfg_sha
    cfg_sha=$(b2sum "${boot_path}/EFI/BOOT/limine.conf" | awk '{print $1}')
    if command -v limine >/dev/null 2>&1; then
        _safe_cp "$bootx64_src" /tmp/limine-tmp.EFI
        limine enroll-config /tmp/limine-tmp.EFI "${cfg_sha}"
        sbsign --key "${sec_dir}/db.key"                --cert "${sec_dir}/db.crt"                --output "${boot_path}/EFI/BOOT/BOOTX64.EFI"                /tmp/limine-tmp.EFI
        rm -f /tmp/limine-tmp.EFI
    else
        echo "  WARNING: limine tool not installed — skipping config hash enrollment"
        echo "  Install limine for full config verification: https://github.com/limine-bootloader/limine"
        local signed_efi="${boot_path}/EFI/BOOT/BOOTX64.EFI.signed"
        _safe_cp "$bootx64_src" "${boot_path}/EFI/BOOT/BOOTX64.EFI"
        sbsign --key "${sec_dir}/db.key"                --cert "${sec_dir}/db.crt"                --output "${signed_efi}"                "${boot_path}/EFI/BOOT/BOOTX64.EFI"
        mv "${signed_efi}" "${boot_path}/EFI/BOOT/BOOTX64.EFI"
    fi

    local keys_src=$(_resolve_path "$artifact_dir" "keys/PK.crt")
    if [ -n "$keys_src" ] && [ "$(dirname "$(realpath "$keys_src" 2>/dev/null || echo "$keys_src")")" != "$(realpath "${boot_path}/keys" 2>/dev/null || echo "${boot_path}/keys")" ]; then
        _copy_uefi_public_keys "$(dirname "$keys_src")" "${boot_path}/keys"
    else
        local base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        if [ -d "${base_dir}/prebuilt/testdata/uefi-keys" ]; then
            _copy_uefi_public_keys "${base_dir}/prebuilt/testdata/uefi-keys" "${boot_path}/keys"
        fi
    fi

    mkdir -p "${output_dir}/img"
    _build_fat_image "${boot_path}" "${output_dir}/img/boot-limine-signed.vfat"
    rm -rf "${boot_path}"
}

build_boot_initos_unsigned() {
    local artifact_dir="${1:?Usage: build_boot_initos_unsigned <artifact_dir> <output_dir>}"
    local output_dir="${2:?Usage: build_boot_initos_unsigned <artifact_dir> <output_dir>}"
    local boot_path=$(mktemp -d)
    local esp_dir="${boot_path}"
    echo "=== Building initos unsigned boot ==="

    mkdir -p "${boot_path}/EFI/BOOT"

    local bzimage_src initrd_src initos_efi_src bootx64_limine_src limine_conf_src config_src
    bzimage_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/bzImage")
    initrd_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initrd.img")
    initos_efi_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initos.EFI")
    [ -z "$initos_efi_src" ] && initos_efi_src=$(_resolve_path "$artifact_dir" "target/x86_64-unknown-uefi/release/efi.efi")

    bootx64_limine_src=$(_resolve_path "$artifact_dir" "boot/EFI/BOOT/BOOTX64.EFI")
    [ -z "$bootx64_limine_src" ] && bootx64_limine_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/BOOTX64.EFI")
    limine_conf_src=$(_resolve_path "$artifact_dir" "boot/EFI/BOOT/limine.conf")
    [ -z "$limine_conf_src" ] && limine_conf_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/limine.conf")
    config_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/config")
    [ -z "$config_src" ] && config_src=$(_resolve_path "$artifact_dir" "config")

    _safe_cp "$bzimage_src" "${boot_path}/EFI/BOOT/bzImage"
    _safe_cp "$initrd_src" "${boot_path}/EFI/BOOT/initrd.img"
    _safe_cp "$bootx64_limine_src" "${boot_path}/EFI/BOOT/BOOTX64.EFI"
    _safe_cp "$initos_efi_src" "${boot_path}/EFI/BOOT/initos.EFI"

    if [ -n "$config_src" ] && [ -f "$config_src" ]; then
        _safe_cp "$config_src" "${esp_dir}/EFI/BOOT/config"
    else
        cat > "${esp_dir}/EFI/BOOT/config" <<EOF
INITOS_INIT=/opt/initos/bin/initos-init-dev console=tty1 loglevel=6 net.ifnames=0 panic=5
EOF
    fi

    local keys_src=$(_resolve_path "$artifact_dir" "keys/PK.crt")
    if [ -n "$keys_src" ] && [ "$(dirname "$(realpath "$keys_src" 2>/dev/null || echo "$keys_src")")" != "$(realpath "${boot_path}/keys" 2>/dev/null || echo "${boot_path}/keys")" ]; then
        _copy_uefi_public_keys "$(dirname "$keys_src")" "${boot_path}/keys"
    else
        local base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        if [ -d "${base_dir}/prebuilt/testdata/uefi-keys" ]; then
            _copy_uefi_public_keys "${base_dir}/prebuilt/testdata/uefi-keys" "${boot_path}/keys"
        fi
    fi

    mkdir -p "${output_dir}/img"
    _build_fat_image "${boot_path}" "${output_dir}/img/boot-initos-unsigned.vfat"
    rm -rf "${boot_path}"
}

build_boot_initos_signed() {
    local artifact_dir="${1:?Usage: build_boot_initos_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local output_dir="${2:?Usage: build_boot_initos_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local sec_dir="${3:-${SECRETS:-/var/run/secrets/uefi-keys}}"
    local boot_path=$(mktemp -d)
    local esp_dir="${boot_path}"
    echo "=== Building initos-signed boot ==="

    mkdir -p "${boot_path}/EFI/BOOT"

    local bzimage_src initrd_src initos_efi_src bootx64_limine_src limine_conf_src config_src
    bzimage_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/bzImage")
    initrd_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initrd.img")
    initos_efi_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initos.EFI")
    [ -z "$initos_efi_src" ] && initos_efi_src=$(_resolve_path "$artifact_dir" "target/x86_64-unknown-uefi/release/efi.efi")
    config_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/config")
    [ -z "$config_src" ] && config_src=$(_resolve_path "$artifact_dir" "config")

    _safe_cp "$bzimage_src" "${boot_path}/EFI/BOOT/bzImage"
    _safe_cp "$initrd_src" "${boot_path}/EFI/BOOT/initrd.img"
    _safe_cp "$initos_efi_src" "${boot_path}/EFI/BOOT/BOOTX64.EFI"
    _safe_cp "$initos_efi_src" "${boot_path}/EFI/BOOT/initos.EFI"

    if [ -n "$config_src" ] && [ -f "$config_src" ]; then
        _safe_cp "$config_src" "${esp_dir}/EFI/BOOT/config"
    else
        cat > "${esp_dir}/EFI/BOOT/config" <<EOF
INITOS_INIT=/opt/initos/bin/initos-init-dev console=tty1 loglevel=6 net.ifnames=0 panic=5
EOF
    fi

    local signed="${boot_path}/EFI/BOOT/BOOTX64.EFI.signed"
    sbsign --key "${sec_dir}/db.key"            --cert "${sec_dir}/db.crt"            --output "${signed}"            "${boot_path}/EFI/BOOT/BOOTX64.EFI"
    mv "${signed}" "${boot_path}/EFI/BOOT/BOOTX64.EFI"

    local key_id=$(openssl x509 -in "${sec_dir}/db.crt" -pubkey -noout 2>/dev/null |         openssl rsa -pubin -outform DER 2>/dev/null |         openssl dgst -sha256 | sed 's/.*= //' | cut -c 1-16)

    echo "  Signing with db.key (KEY_ID: ${key_id})..."

    openssl dgst -sha256 -sign "${sec_dir}/db.key"         -out "${esp_dir}/EFI/BOOT/${key_id}.sig"         "${esp_dir}/EFI/BOOT/config"

    openssl dgst -sha256 -sign "${sec_dir}/db.key"         -out "${esp_dir}/EFI/BOOT/${key_id}.kernel.sig"         "${esp_dir}/EFI/BOOT/bzImage"

    openssl dgst -sha256 -sign "${sec_dir}/db.key"         -out "${esp_dir}/EFI/BOOT/${key_id}.initrd.sig"         "${esp_dir}/EFI/BOOT/initrd.img"

    local keys_src=$(_resolve_path "$artifact_dir" "keys/PK.crt")
    if [ -n "$keys_src" ] && [ "$(dirname "$(realpath "$keys_src" 2>/dev/null || echo "$keys_src")")" != "$(realpath "${boot_path}/keys" 2>/dev/null || echo "${boot_path}/keys")" ]; then
        _copy_uefi_public_keys "$(dirname "$keys_src")" "${boot_path}/keys"
    else
        local base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        if [ -d "${base_dir}/prebuilt/testdata/uefi-keys" ]; then
            _copy_uefi_public_keys "${base_dir}/prebuilt/testdata/uefi-keys" "${boot_path}/keys"
        fi
    fi

    mkdir -p "${output_dir}/img"
    _build_fat_image "${boot_path}" "${output_dir}/img/boot-initos-signed.vfat"
    rm -rf "${boot_path}"
}

# --- Dispatch ---
# When run directly (not sourced), dispatch to the requested function.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ -z "${1+x}" ]]; then
        echo "setup_signed.sh — General-purpose Ed25519 image signing tool"
        echo ""
        echo "Usage: $0 <command> [args...]"
        echo ""
        echo "Commands:"
        echo "  sign_init                         Generate EFI and image signing keys"
        echo "  sign_digest <file> <key> <out>    Sign a binary digest"
        echo "  sign_hex_digest <hex> <key> <out> Sign a hex digest string"
        echo "  image <dir> <file>                Sign an fsverity digest for an image"
        echo "  efi <sec_dir> <boot_dir>          Sign BOOTX64.EFI in a boot directory"
        echo "  artifacts <out_dir> [artifact_dir] Sign a Nix artifact tree"
        echo "  build_dmverity_boot               Build dm-verity boot config"
        echo "  build_boot_limine_unsigned <artifact_dir> <output_dir>"
        echo "  build_boot_limine_signed <artifact_dir> <output_dir> [keys]"
        echo "  build_boot_initos_unsigned <artifact_dir> <output_dir>"
        echo "  build_boot_initos_signed <artifact_dir> <output_dir> [keys]"
        exit 0
    fi
    "$@"
fi
