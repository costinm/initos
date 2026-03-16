#!/usr/bin/env bash
#
# setup_signed.sh 
# - gets verity digest and creates Ed25519 signatures for images.
# - signs the bootstrap EFI file, locking the image public key in the config
#   along with initrd and kernel SHAs.
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
#   setup_signed.sh check_prerequisites
#   setup_signed.sh generate_keypair <output_dir>
#   setup_signed.sh sign_digest <digest_file> <private_key_pem> <output_sig>
#   setup_signed.sh create_signed_image <image_path> <output_dir> [private_key_pem]

set -euo pipefail
PATH="/usr/sbin:/sbin:${PATH}"
SECRETS=${SECRETS:-/var/run/secrets/uefi-keys}

# --- Prerequisite checks ---

# Check if a command is available.
# Usage: check_command <cmd> <package_name>
check_command() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: '$1' not found. Please install $2."
        return 1
    fi
}

# Check all required tools.
check_prerequisites() {
    local ok=0
    check_command mkfs.erofs "erofs-utils" || ok=1
    check_command openssl "openssl" || ok=1
    if [[ ${ok} -ne 0 ]]; then
        return 1
    fi
    echo "Prerequisites OK"
}

# --- Key generation ---

# Generate an Ed25519 keypair.
# Usage: generate_keypair <output_dir>
# Output files:
#   ${SECRETS}/image_key.pem  - private key (PEM)
#   ${SECRETS}/image_key.raw  - raw 32-byte private key seed (wireguard/libsodium compatible)
#   ${SECRETS}/image_key_pub.pem   - public key (PEM)
#   ${SECRETS}/image_key.pub.b64      - raw public key (base64-encoded, 44 chars)
generate_keypair() {
    local output_dir="${1:?Usage: generate_keypair <output_dir>}"
    if [ -f "${SECRETS}/image_key.pem" ]; then
        echo "Private key already exists: ${SECRETS}/image_key.pem"
        return 0
    fi

    mkdir -p "${SECRETS}"

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


# Generate the key pairs for signing the kernel and the disk image.
# This is done before install - as a separate step/process - the rest can be automated easily,
# but signing must be done on a secure machine and is specific to each user.
sign_init() {
  local u=${DOMAIN:-mesh.internal}


  if [ -f ${SECRETS}/root.key ] ; then
    echo "Keys already exist"
    return 0
  fi

   
  # Alpine only
  #efi-mkkeys -s ${u} -o ${SECRETS}
 
  # Debian - sbsigntool, efitools, openssl
  (
     cd ${SECRETS} 
     openssl req -new -x509 -newkey rsa:2048 \
        -nodes -keyout PK.key -out PK.crt 
     cert-to-siglist PK.crt PK.esl 
     sign-efi-sig-list -k PK.key -c PK.crt PK PK.esl PK.auth
    
     openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=kek.mesh.local/" \
        -keyout KEK.key -out KEK.crt
     cert-to-siglist KEK.crt KEK.esl

     sign-efi-sig-list -k PK.key -c PK.crt KEK KEK.esl KEK.auth

    openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=My Signature Database Key/" \
        -keyout db.key -out db.crt    
    cert-to-siglist db.crt db.esl
    sign-efi-sig-list -k KEK.key -c KEK.crt db db.esl db.auth
   )

  # Generate a 'mesh root' - both SSH and https.  
  # Will be bundled on all signed images, and used to encrypt the LUKS pass.
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out ${SECRETS}/root.key

  openssl ec -in ${SECRETS}/root.key -pubout -out \
    ${SECRETS}/root.pem
  
  ssh-keygen -y -f ${SECRETS}/root.key > ${SECRETS}/authorized_keys

  minisign -GW -s ${SECRETS}/minisign.key -p ${SECRETS}/minisign.pub
  PUB=$(sed -n '2p' ${SECRETS}/minisign.pub)

  echo $PUB
  #cat ${SECRETS}/minisign.pub

  cat ${SECRETS}/authorized_keys
}


# --- Signing ---

# Sign a binary digest file with an Ed25519 private key.
# Usage: sign_digest <digest_file> <private_key_pem> <output_sig>
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
    generate_keypair "${SECRETS:-${out}/test/secrets}"

    # Compute the fsverity digest offline (does not require root/mounting)
    local digest_hex
    digest_hex=$(fsverity digest "${img_name}" | awk '{print $1}' | sed 's/^sha256://')
    echo -n "${digest_hex}" | xxd -r -p > "/tmp/digest.bin"

    # Sign the digest
    sign_digest "/tmp/digest.bin" \
      "${SECRETS}/image_key.pem" \
      "${img_name}.sig"
}

# Sign the boot EFI - original limine required embedding the SHA
# of the config, and the initrd/kernel into config.
# 
# Instead - EFI will verify anything signed by PK.key
# TODO: may also use db.key
efi() {
    local sec_dir=${1:?Usage: efi <sec_dir>}
    local boot=${2:?Usage: efi <sec_dir> <boot_dir>}

    mkdir -p "${boot}/EFI/BOOT"
    
    PUB_KEY_B64=$(cat "${sec_dir}/image_key.pub.b64")

    echo "Signing BOOTX64.EFI..."

    sbsign --key "${sec_dir}/db.key" \
           --cert "${sec_dir}/db.crt" \
           --output  "${boot}/EFI/BOOT/BOOTX64.EFI" \
           "${boot}/EFI/BOOT/BOOTX64.EFI"
}

build_dmverity_boot() {
    ROOTFS_IMG="${out}/disks/state/img/initos.erofs"
    INITOS_IMG="${out}/test/initos.dmverity"

    echo "Generating ${INITOS_IMG} with appended dm-verity..."
    cp "${ROOTFS_IMG}" "${INITOS_IMG}"
    
    HASH_OFFSET=$(stat -c %s "${INITOS_IMG}")
    
    VERITY_OUT=$(/sbin/veritysetup format --hash-offset=$HASH_OFFSET "${INITOS_IMG}" "${INITOS_IMG}")
    
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

# --- Dispatch ---
# When run directly (not sourced), dispatch to the requested function.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ -z "${1+x}" ]]; then
        echo "setup_signed.sh — General-purpose Ed25519 image signing tool"
        echo ""
        echo "Usage: $0 <command> [args...]"
        echo ""
        echo "Commands:"
        echo "  check_prerequisites              Check required tools"
        echo "  generate_keypair <dir>            Generate Ed25519 keypair"
        echo "  sign_digest <file> <key> <out>    Sign a binary digest"
        echo "  sign_hex_digest <hex> <key> <out> Sign a hex digest string"
        echo "  create_signed_offline <img> <dir> Create test artifacts (offline)"
        exit 0
    fi
    "$@"
fi
