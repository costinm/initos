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
#   sign.sh sign_init
#   sign.sh artifacts <output_dir> [kernel-dir] [artifacts-dir]

set -euo pipefail
PATH="/usr/sbin:/sbin:${PATH}"

SECRETS=${SECRETS:-/var/run/secrets/uefi-keys}
NIX_PROFILE=${NIX_PROFILE:-${PWD}/target/nix/profiles/profile}

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

        openssl x509 -in PK.crt -outform DER -out PK.cer
        ${cert_to_siglist} PK.crt PK.esl 
        sign-efi-sig-list -k PK.key -c PK.crt PK PK.esl PK.auth
        
        openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=kek.efi/" \
            -keyout KEK.key -out KEK.crt

        openssl x509 -in KEK.crt -outform DER -out KEK.cer
        ${cert_to_siglist} KEK.crt KEK.esl
        sign-efi-sig-list -k PK.key -c PK.crt KEK KEK.esl KEK.auth

        openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=db.efi/" \
            -keyout db.key -out db.crt    

        openssl x509 -in db.crt -outform DER -out db.cer
        ${cert_to_siglist} db.crt db.esl
        sign-efi-sig-list -k KEK.key -c KEK.crt db db.esl db.auth
    )

    # Generate a 'mesh root' - both SSH and https.  
    # Will be bundled on all signed images, and used to encrypt the LUKS pass.
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out ${SECRETS}/root.key

    openssl ec -in ${SECRETS}/root.key -pubout -out \
        ${SECRETS}/root.pem
    
    #ssh-keygen -y -f ${SECRETS}/root.key > ${SECRETS}/authorized_keys

    # SSL and SSH key is the real public - minisign is using the sha.

    #minisign -GW -s ${SECRETS}/minisign.key -p ${SECRETS}/minisign.pub
    #PUB=$(sed -n '2p' ${SECRETS}/minisign.pub)

    #echo $PUB
    #cat ${SECRETS}/minisign.pub

    #cat ${SECRETS}/authorized_keys

    echo "Keys generated successfully"
}

generate_ed25519_keypair() {
    local secrets_dir="${1:?Usage: generate_ed25519_keypair <secrets_dir>}"

    echo "Generating Ed25519 keypair..."
    if ! openssl genpkey -algorithm ed25519 -out "${secrets_dir}/image_key.pem" 2>/dev/null; then
        echo "ERROR: Failed to generate Ed25519 private key in ${secrets_dir}/image_key.pem" >&2
        return 1
    fi
    if ! openssl pkey -in "${secrets_dir}/image_key.pem" -pubout -out "${secrets_dir}/image_key_pub.pem" 2>/dev/null; then
        echo "ERROR: Failed to extract Ed25519 public key from ${secrets_dir}/image_key.pem" >&2
        return 1
    fi

    local pub_key_b64
    if ! pub_key_b64=$(openssl pkey -in "${secrets_dir}/image_key.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64); then
        echo "ERROR: Failed to extract raw Ed25519 public key bytes from ${secrets_dir}/image_key.pem" >&2
        return 1
    fi
    echo -n "${pub_key_b64}" > "${secrets_dir}/image_key.pub.b64"

    if ! openssl pkey -in "${secrets_dir}/image_key.pem" -outform DER 2>/dev/null | tail -c 32 > "${secrets_dir}/image_key.raw"; then
        echo "ERROR: Failed to extract raw Ed25519 private key seed from ${secrets_dir}/image_key.pem" >&2
        return 1
    fi

    echo "  Private key: ${secrets_dir}/image_key.pem"
    echo "  Raw privkey: ${secrets_dir}/image_key.raw (32 bytes)"
    echo "  Public key:  ${secrets_dir}/image_key_pub.pem"
    echo "  Pub base64:  ${pub_key_b64}"
}

# Sign a binary digest file with an Ed25519 private key.
# Usage: sign_digest <digest_file> <private_key_pem> <output_sig>
# This is used for the STATE erofs disk.
sign_digest() {
    local digest_file="${1:?Usage: sign_digest <digest_file> <private_key_pem> <output_sig>}"
    local private_key="${2:?Usage: sign_digest <digest_file> <private_key_pem> <output_sig>}"
    local output_sig="${3:?Usage: sign_digest <digest_file> <private_key_pem> <output_sig>}"

    if [ ! -f "${digest_file}" ]; then
        echo "ERROR: Digest file not found: ${digest_file}" >&2
        return 1
    fi
    if [ ! -f "${private_key}" ]; then
        echo "ERROR: Private key not found: ${private_key}" >&2
        return 1
    fi

    echo "Signing digest..."
    if ! openssl pkeyutl -sign -rawin \
        -inkey "${private_key}" \
        -in "${digest_file}" \
        -out "${output_sig}" 2>/dev/null; then
        echo "ERROR: openssl pkeyutl failed to sign digest" >&2
        return 1
    fi

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

db_key_id() {
    local cert="${1:?Usage: db_key_id <cert>}"

    openssl x509 -in "${cert}" -pubkey -noout 2>/dev/null | \
        openssl pkey -pubin -pubout -outform DER 2>/dev/null | \
        openssl dgst -sha256 | \
        sed 's/.*= //' | \
        cut -c 1-16
}



# Sign artifacts without natively enabling fs-verity (computes digest offline).
# Usage: image <image_dir> <file_name>
image() {
    local image_dir="${1:?Usage: image <image_dir> <file_name>}"
    local filen="${2:?Usage: image <image_dir> <file_name>}"
    
    local img_name
    img_name="${image_dir}/${filen}"

    if [ ! -f "${img_name}" ]; then
        echo "ERROR: Image file not found: ${img_name}" >&2
        return 1
    fi

    sign_init

    local digest_hex digest_bin
    if ! digest_hex=$(fsverity digest "${img_name}" | awk '{print $1}' | sed 's/^sha256://'); then
        echo "ERROR: Failed to compute fsverity digest for ${img_name}" >&2
        return 1
    fi
    digest_bin="$(mktemp)"
    echo -n "${digest_hex}" | xxd -r -p > "${digest_bin}"

    if [ -f "${SECRETS}/image_key.pem" ]; then
        if ! sign_digest "${digest_bin}" \
          "${SECRETS}/image_key.pem" \
          "${img_name}.sig"; then
            echo "ERROR: Failed to sign digest with Ed25519 key for ${img_name}" >&2
            rm -f "${digest_bin}"
            return 1
        fi
    fi

    if [ -f "${SECRETS}/db.key" ]; then
        local key_id
        if ! key_id=$(db_key_id "${SECRETS}/db.crt"); then
            echo "ERROR: Failed to compute db key ID from ${SECRETS}/db.crt" >&2
            rm -f "${digest_bin}"
            return 1
        fi
        if ! openssl dgst -sha256 -sign "${SECRETS}/db.key" \
            -out "${img_name}.${key_id}.db.sig" \
            "${digest_bin}"; then
            echo "ERROR: Failed to sign digest with db.key for ${img_name}" >&2
            rm -f "${digest_bin}"
            return 1
        fi
        echo "  DB signature: ${img_name}.${key_id}.db.sig"
    else
        echo "ERROR: db.key not found in ${SECRETS}" >&2
        rm -f "${digest_bin}"
        return 1
    fi
    rm -f "${digest_bin}"
}

_build_fat_image() {
    local boot_path="${1:?Usage: _build_fat_image <boot_path> <img_file>}"
    local img_file="${2:?Usage: _build_fat_image <boot_path> <img_file>}"
    local label=${3:-INITOSBOOT}

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
    mformat -i "${img_file}" -F -v "${label}" ::
    (cd "${boot_path}" && mcopy -i "${img_file}" -s ./* ::)

    echo "  Created: ${img_file} ($(du -h "${img_file}" | cut -f1))"
}

_sign_kernel_module() {
    local sign_file="${1:?Usage: _sign_kernel_module <sign-file> <key> <cert> <module>}"
    local key="${2:?Usage: _sign_kernel_module <sign-file> <key> <cert> <module>}"
    local cert="${3:?Usage: _sign_kernel_module <sign-file> <key> <cert> <module>}"
    local module="${4:?Usage: _sign_kernel_module <sign-file> <key> <cert> <module>}"

    case "${module}" in
        *.ko)
            "${sign_file}" sha256 "${key}" "${cert}" "${module}"
            ;;
        *)
            echo "ERROR: unsupported kernel module path: ${module}" >&2
            return 1
            ;;
    esac
}

_strip_kernel_module_signature() {
    local module="${1:?Usage: _strip_kernel_module_signature <module>}"
    local magic="~Module signature appended~"
    local magic_len=28
    local sig_info_len=12
    local size sig_len_offset bytes sig_len unsigned_size

    while [ "$(stat -c %s "${module}")" -ge $((magic_len + sig_info_len)) ] && \
          tail -c "${magic_len}" "${module}" | cmp -s - <(printf '%s\n' "${magic}"); do
        size=$(stat -c %s "${module}")
        sig_len_offset=$((size - magic_len - 4))
        bytes=$(dd if="${module}" bs=1 skip="${sig_len_offset}" count=4 status=none | od -An -t u1)
        # shellcheck disable=SC2086
        set -- ${bytes}
        sig_len=$((($1 << 24) + ($2 << 16) + ($3 << 8) + $4))
        unsigned_size=$((size - magic_len - sig_info_len - sig_len))
        if [ "${unsigned_size}" -le 0 ] || [ "${unsigned_size}" -ge "${size}" ]; then
            echo "ERROR: invalid existing kernel module signature trailer in ${module}" >&2
            return 1
        fi
        truncate -s "${unsigned_size}" "${module}"
    done
}

_print_module_signing_key_info() {
    local cert="${1:?Usage: _print_module_signing_key_info <cert> <modules-stage>}"
    local stage="${2:?Usage: _print_module_signing_key_info <cert> <modules-stage>}"

    local db_serial db_subject_key_id db_pubkey_id
    db_serial=$(
        openssl x509 -in "${cert}" -noout -serial 2>/dev/null | \
            sed 's/^serial=//' | \
            sed 's/../&:/g; s/:$//'
    )
    db_subject_key_id=$(
        openssl x509 -in "${cert}" -noout -ext subjectKeyIdentifier 2>/dev/null | \
            awk 'NF && $0 !~ /Subject Key Identifier/ { gsub(/^[[:space:]]+/, ""); print; exit }'
    )
    db_pubkey_id=$(
        openssl x509 -in "${cert}" -pubkey -noout 2>/dev/null | \
            openssl pkey -pubin -outform DER 2>/dev/null | \
            openssl dgst -sha256 2>/dev/null | \
            sed 's/.*= //' | \
            cut -c 1-16
    )

    echo "  db.crt serial: ${db_serial:-unknown}"
    echo "  db.crt subject key id: ${db_subject_key_id:-unknown}"
    echo "  db.crt pubkey sha256 id: ${db_pubkey_id:-unknown}"

    if ! command -v modinfo >/dev/null 2>&1; then
        echo "  module sig_key sample: skipped (modinfo not found)"
        return 0
    fi

    local sample signer sig_key
    sample=$(find "${stage}" -type f -path '*/fs/btrfs/btrfs.ko' -print -quit)
    if [ -z "${sample}" ]; then
        sample=$(find "${stage}" -type f -name '*.ko' -print -quit)
    fi
    if [ -z "${sample}" ]; then
        echo "  module sig_key sample: skipped (no .ko files found)"
        return 0
    fi

    signer=$(modinfo -F signer "${sample}" 2>/dev/null || true)
    sig_key=$(modinfo -F sig_key "${sample}" 2>/dev/null || true)

    echo "  module sample: ${sample#${stage}/}"
    echo "  module signer: ${signer:-unknown}"
    echo "  module sig_key: ${sig_key:-unknown}"
}

_build_signed_modules_image() {
    local modules_src="${1:?Usage: _build_signed_modules_image <modules-dir> <kernel-dir> <output-img-dir> <secrets-dir>}"
    local kernel_dir="${2:?Usage: _build_signed_modules_image <modules-dir> <kernel-dir> <output-img-dir> <secrets-dir>}"
    local img_dir="${3:?Usage: _build_signed_modules_image <modules-dir> <kernel-dir> <output-img-dir> <secrets-dir>}"
    local sec_dir="${4:?Usage: _build_signed_modules_image <modules-dir> <kernel-dir> <output-img-dir> <secrets-dir>}"

    local modules_name sign_file stage count stripped before_size after_size
    modules_name=$(basename "${modules_src}")
    sign_file="${kernel_dir}/sign-file"
    if [ ! -x "${sign_file}" ]; then
        echo "ERROR: kernel module signer not found: ${sign_file}" >&2
        return 1
    fi

    stage=$(mktemp -d)
    cp -a "${modules_src}/." "${stage}/"
    chmod -R u+w "${stage}"

    if find "${stage}" -type f \( -name '*.ko.xz' -o -name '*.ko.zst' -o -name '*.ko.gz' \) | grep -q .; then
        echo "ERROR: compressed kernel modules found in ${modules_src}; disable module compression in the kernel config" >&2
        rm -rf "${stage}"
        return 1
    fi

    count=0
    stripped=0
    while IFS= read -r -d '' module; do
        before_size=$(stat -c %s "${module}")
        _strip_kernel_module_signature "${module}"
        after_size=$(stat -c %s "${module}")
        if [ "${after_size}" -lt "${before_size}" ]; then
            stripped=$((stripped + 1))
        fi
        _sign_kernel_module "${sign_file}" "${sec_dir}/db.key" "${sec_dir}/db.crt" "${module}"
        count=$((count + 1))
    done < <(find "${stage}" -type f -name '*.ko' -print0)

    if [ "${stripped}" -gt 0 ]; then
        echo "  Stripped existing signatures from ${stripped} kernel modules"
    fi
    echo "  Signed ${count} kernel modules with db.key"
    _print_module_signing_key_info "${sec_dir}/db.crt" "${stage}"
    mkfs.erofs -zlz4 "${img_dir}/${modules_name}.erofs" "${stage}"
    rm -rf "${stage}"
}

_copy_kernel_bzimage() {
    local kernel_dir="${1:?Usage: _copy_kernel_bzimage <kernel-dir> <output-bzimage>}"
    local output_bzimage="${2:?Usage: _copy_kernel_bzimage <kernel-dir> <output-bzimage>}"

    if [ ! -f "${kernel_dir}/bzImage" ]; then
        echo "ERROR: kernel_dir must contain bzImage" >&2
        return 1
    fi

    mkdir -p "$(dirname "${output_bzimage}")"
    if [ -f "${output_bzimage}" ]; then
        chmod u+w "${output_bzimage}"
    fi
    cp "${kernel_dir}/bzImage" "${output_bzimage}"
}

# Sign a Nix artifact tree produced by .#initos-signer.
artifacts() {
    local output_dir="${1:?Usage: artifacts <output_dir> [kernel_dir] [artifact_dir]}"
    mkdir -p "${output_dir}/img"
    output_dir=$(cd "${output_dir}" && pwd)

    local kernel_dir="${2:-}"
    local artifact_dir="${3:-}"
    local sec_dir="${SECRETS:-/var/run/secrets/uefi-keys}"
    local profile_dir="${NIX_PROFILE:-${PWD}/target/nix/profiles/profile}"

    # Auto-detect kernel_dir
    if [ -z "${kernel_dir}" ]; then
        
        if [ -f "/opt/kernel-image/bzImage" ]; then
            # docker image
            kernel_dir="/opt/kernel-image"
        elif [ -f "${profile_dir}/opt/kernel-image/bzImage" ]; then
            # Nix profile (e.g., .../result/opt/kernel-image/)
            kernel_dir="$(cd "${profile_dir}/opt/kernel-image" && pwd)"
        elif [ -f "/mnt/kernel-image/opt/kernel-image/bzImage" ]; then
            # Mounted from a docker image
            kernel_dir="/mnt/kernel-image/opt/kernel-image"
        fi
    fi

    # Require kernel artifacts
    if [ -z "${kernel_dir}" ] || [ ! -f "${kernel_dir}/bzImage" ]; then
        echo "ERROR: Kernel artifacts not found. Please provide kernel_dir with bzImage." >&2
        exit 1
    fi

    # Auto-detect artifact_dir
    if [ -z "${artifact_dir}" ]; then
        if [ -f "/img/initos.erofs" ]; then
            # Docker image
	    artifact_dir="/"
        elif [ -f "${profile_dir}/img/initos.erofs" ]; then
            artifact_dir="${profile_dir}"
        elif [ -f "${PWD}/target/artifacts/img/initos.erofs" ]; then
            artifact_dir="${PWD}/target/artifacts"
        fi
    fi

    if [ -z "${artifact_dir}" ] || [ ! -f "${artifact_dir}/img/initos.erofs" ]; then
        echo "ERROR: initos artifacts not found. Please provide artifact_dir." >&2
        exit 1
    fi

    sign_init
    local bzimage
    bzimage="${output_dir}/kernel/bzImage"
    _copy_kernel_bzimage "${kernel_dir}" "${bzimage}"

    # Copy initos.erofs to output
    if [ -f "${output_dir}/img/initos.erofs" ]; then
        chmod u+w "${output_dir}/img/initos.erofs"
    fi
    cp "${artifact_dir}/img/initos.erofs" "${output_dir}/img/"
    chmod u+w "${output_dir}/img/initos.erofs"
    image "${output_dir}/img" "initos.erofs"

    # Build signed module images from unpacked kernel modules when available.
    # Fall back to copying prebuilt EROFS images for older kernel artifacts.
    shopt -s nullglob
    local module_dirs=()
    local module_candidate module_dir
    for module_candidate in "${kernel_dir}"/modules-*; do
        [ -d "${module_candidate}" ] && module_dirs+=("${module_candidate}")
    done
    for module_dir in "${module_dirs[@]}"; do
        _build_signed_modules_image "${module_dir}" "${kernel_dir}" "${output_dir}/img" "${sec_dir}"
    done
    if [ "${#module_dirs[@]}" -eq 0 ]; then
        for m in "${kernel_dir}"/modules-*.erofs; do
            if [ -f "$m" ]; then
                local dest="${output_dir}/img/$(basename "$m")"
                if [ -f "${dest}" ]; then
                    chmod u+w "${dest}"
                fi
                cp "$m" "${output_dir}/img/"
            fi
        done
    fi
    shopt -u nullglob
    if [ -f "${kernel_dir}/firmware.erofs" ]; then
        if [ -f "${output_dir}/img/firmware.erofs" ]; then
            chmod u+w "${output_dir}/img/firmware.erofs"
        fi
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

    cp "${bzimage}" "${boot_stage}/EFI/BOOT/bzImage"

    # Build the three boot variants from the staging area
    #build_boot_limine_unsigned "${boot_stage}" "${output_dir}" "${sec_dir}"
    build_boot_initos_signed "${boot_stage}" "${output_dir}" "${sec_dir}"
    #build_boot_limine_signed "${boot_stage}" "${output_dir}" "${sec_dir}"

    rm -rf "${boot_stage}"
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
    local dst_dir="${1:?Usage: _copy_uefi_public_keys <dst_dir> [secrets_dir]}"
    local sec_dir="${2:-${SECRETS:-/var/run/secrets/uefi-keys}}"
    local SECRETS="${sec_dir}"

    if [ -n "${NIX_BUILD_TOP:-}" ]; then
        echo "Nix build environment detected — skipping public keys installation for unsigned package."
        return 0
    fi

    echo "Installing UEFI public keys into ${dst_dir}..."
    mkdir -p "${dst_dir}"
    for f in PK.cer PK.crt PK.esl PK.auth KEK.cer KEK.crt KEK.auth KEK.esl db.cer db.esl db.crt db.auth root.pem ; do
        if [ -f "${SECRETS}/${f}" ]; then
            cp "${SECRETS}/${f}" "${dst_dir}/"
        else
             echo "ERROR: Missing required key ${SECRETS}/${f}" >&2
             exit 1
        fi
    done
    for f in image_key_pub.pem image_key.pub.b64; do
        if [ -f "${SECRETS}/${f}" ]; then
            cp "${SECRETS}/${f}" "${dst_dir}/"
        else
            echo "  Optional key not found (skipping): ${SECRETS}/${f}"
        fi
    done
}


build_boot_limine_unsigned() {
    local artifact_dir="${1:?Usage: build_boot_limine_unsigned <artifact_dir> <output_dir> [secrets_dir]}"
    local output_dir="${2:?Usage: build_boot_limine_unsigned <artifact_dir> <output_dir> [secrets_dir]}"
    local sec_dir="${3:-${SECRETS:-/var/run/secrets/uefi-keys}}"
    local SECRETS="${sec_dir}"
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

    _copy_uefi_public_keys "${boot_path}/keys" "${sec_dir}"

    mkdir -p "${output_dir}/img"
    _build_fat_image "${boot_path}" "${output_dir}/img/boot-limine-unsigned.vfat" "INITOS-DEV"
    rm -rf "${boot_path}"d
}

build_boot_limine_signed() {
    local artifact_dir="${1:?Usage: build_boot_limine_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local output_dir="${2:?Usage: build_boot_limine_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local sec_dir="${3:-${SECRETS:-/var/run/secrets/uefi-keys}}"
    local SECRETS="${sec_dir}"

    local boot_path=$(mktemp -d)
    echo "=== Building limine-signed boot ==="

    mkdir -p "${boot_path}/EFI/BOOT"

    local bzimage_src initrd_src bootx64_src
    bzimage_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/bzImage")
    initrd_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initrd.img")
    bootx64_src=$(_resolve_path "$artifact_dir" "boot/EFI/BOOT/BOOTX64.EFI")
    [ -z "$bootx64_src" ] && bootx64_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/BOOTX64.EFI")

    _safe_cp "$bzimage_src" "${boot_path}/EFI/BOOT/bzImage"
    _safe_cp "$initrd_src" "${boot_path}/EFI/BOOT/initrd.img"
    
    local sha_kernel sha_initrd
    sha_kernel=$(b2sum "${boot_path}/EFI/BOOT/bzImage" | awk '{print $1}')
    sha_initrd=$(b2sum "${boot_path}/EFI/BOOT/initrd.img" | awk '{print $1}')

    local cmdline="${INITOS_CMDLINE:-rdinit=/init console=tty1 console=ttyS0,115200 console=hvc0 net.ifnames=0 panic=5 loglevel=6}"
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

        sbsign --key "${sec_dir}/db.key" \
               --cert "${sec_dir}/db.crt" \
               --output "${boot_path}/EFI/BOOT/BOOTX64.EFI" \
               /tmp/limine-tmp.EFI
        rm -f /tmp/limine-tmp.EFI
    else
        echo "  WARNING: limine tool not installed — skipping config hash enrollment"
        echo "  Install limine for full config verification: https://github.com/limine-bootloader/limine"
        return
    fi

    _copy_uefi_public_keys "${boot_path}/keys" "${sec_dir}"

    mkdir -p "${output_dir}/img"
    _build_fat_image "${boot_path}" "${output_dir}/img/boot-limine-signed.vfat" "INITOSL"
    rm -rf "${boot_path}"
}

build_boot_initos_signed() {
    local artifact_dir="${1:?Usage: build_boot_initos_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local output_dir="${2:?Usage: build_boot_initos_signed <artifact_dir> <output_dir> [secrets_dir]}"
    local sec_dir="${3:-${SECRETS:-/var/run/secrets/uefi-keys}}"
    
    local SECRETS="${sec_dir}"

    local boot_path=$(mktemp -d)
    
    echo "=== Building initos-signed boot ==="

    mkdir -p "${boot_path}/EFI/BOOT"

    local bzimage_src initrd_src initos_efi_src

    bzimage_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/bzImage")
    initrd_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initrd.img")
    initos_efi_src=$(_resolve_path "$artifact_dir" "EFI/BOOT/initos.EFI")
    [ -z "$initos_efi_src" ] && initos_efi_src=$(_resolve_path "$artifact_dir" "target/x86_64-unknown-uefi/release/efi.efi")

    _safe_cp "$bzimage_src" "${boot_path}/EFI/BOOT/bzImage"
    _safe_cp "$initrd_src" "${boot_path}/EFI/BOOT/initrd.img"
    _safe_cp "$initos_efi_src" "${boot_path}/EFI/BOOT/initos.EFI"
    
    local cmdline="${INITOS_CMDLINE:-rdinit=/init console=tty1 console=ttyS0,115200 console=hvc0 loglevel=6 net.ifnames=0 panic=5}"

    printf '%s\n' "${cmdline}" > "${boot_path}/EFI/BOOT/config"

    local signed="${boot_path}/EFI/BOOT/BOOTX64.EFI"

    sbsign --key "${sec_dir}/db.key" \
           --cert "${sec_dir}/db.crt" \
           --output "${signed}" \
           "${boot_path}/EFI/BOOT/initos.EFI"
    
    local key_id
    key_id=$(db_key_id "${sec_dir}/db.crt")

    echo "  Signing with db.key (KEY_ID: ${key_id})..."

    openssl dgst -sha256 -sign "${sec_dir}/db.key" \
            -out "${boot_path}/EFI/BOOT/${key_id}.sig" \
            "${boot_path}/EFI/BOOT/config"

    openssl dgst -sha256 -sign "${sec_dir}/db.key" \
            -out "${boot_path}/EFI/BOOT/${key_id}.kernel.sig"  \
            "${boot_path}/EFI/BOOT/bzImage"

    openssl dgst -sha256 -sign "${sec_dir}/db.key" \
            -out "${boot_path}/EFI/BOOT/${key_id}.initrd.sig" \
            "${boot_path}/EFI/BOOT/initrd.img"

    _copy_uefi_public_keys "${boot_path}/keys" "${sec_dir}"

    mkdir -p "${output_dir}/img"
    _build_fat_image "${boot_path}" "${output_dir}/img/boot-initos-signed.vfat" "INITOSB"
    rm -rf "${boot_path}"
}

show_help() {
    echo "sign.sh — Initos signing and image generation tool"
    echo ""
    echo "Usage: $0 <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  sign_init                              Generate EFI and image signing keys"
    echo "  sign_digest <file> <key> <out>         Sign a binary digest"
    echo "  sign_hex_digest <hex> <key> <out>      Sign a hex digest string"
    echo "  image <dir> <file>                     Sign an fsverity digest for an image"
    echo "  artifacts <out_dir> [kernel_dir] [artifact_dir]"
    echo "                                         Sign a Nix artifact tree"
    echo "  build_boot_limine_unsigned <artifact_dir> <output_dir> [keys]"
    echo "  build_boot_limine_signed <artifact_dir> <output_dir> [keys]"
    echo "  build_boot_initos_signed <artifact_dir> <output_dir> [keys]"
    echo "  help                                   Show this help"
}

    if [[ -z "${1+x}" ]]; then
        set -- artifacts /tmp/initos
    fi
    case "${1}" in
        help)
            show_help
            exit 0
            ;;
    esac
    "$@"
