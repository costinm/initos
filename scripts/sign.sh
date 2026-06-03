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
#   setup_signed.sh sign_init
#   setup_signed.sh sign_digest <digest_file> <private_key_pem> <output_sig>
#   setup_signed.sh create_signed_image <image_path> <output_dir> [private_key_pem]

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

# Sign a Nix artifact tree produced by .#initos-artifacts.
# Usage: artifacts <artifact_dir> <output_dir> [secrets_dir]
artifacts() {
    local artifact_dir="${1:?Usage: artifacts <artifact_dir> <output_dir> [secrets_dir]}"
    local output_dir="${2:?Usage: artifacts <artifact_dir> <output_dir> [secrets_dir]}"
    local sec_dir="${3:-${SECRETS}}"

    SECRETS="${sec_dir}"
    export SECRETS
    sign_init

    rm -rf "${output_dir}"
    mkdir -p "${output_dir}/img" "${output_dir}/boot"

    cp -R "${artifact_dir}/boot/." "${output_dir}/boot/"
    cp -R "${artifact_dir}/img/." "${output_dir}/img/"
    chmod -R u+w "${output_dir}/boot" "${output_dir}/img"

    if [ -f "${sec_dir}/image_key.pub.b64" ] &&
       ! grep -q 'INITOS_PUB_KEY=' "${output_dir}/boot/EFI/BOOT/config"; then
        printf ' INITOS_PUB_KEY=%s\n' "$(cat "${sec_dir}/image_key.pub.b64")" \
          >> "${output_dir}/boot/EFI/BOOT/config"
    fi

    image "${output_dir}/img" "initos.erofs"
    efi "${sec_dir}" "${output_dir}/boot"
    _build_fat_image "${output_dir}/boot" "${output_dir}/img/boot-initos-signed.img"
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
        echo "  artifacts <result> <out> [keys]   Sign a Nix artifact tree"
        echo "  build_dmverity_boot               Build dm-verity boot config"
        exit 0
    fi
    "$@"
fi
