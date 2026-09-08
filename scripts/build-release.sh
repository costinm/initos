#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir="${1:-${repo_root}/target/release}"
revision="${REVISION:-$(git -C "${repo_root}" rev-parse HEAD)}"
secrets_dir="${SECRETS:-}"

if [ -z "${secrets_dir}" ] || [ ! -d "${secrets_dir}" ]; then
    echo "ERROR: SECRETS must name the signing-key directory" >&2
    exit 1
fi
if [ -e "${output_dir}" ] && [ -n "$(find "${output_dir}" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
    echo "ERROR: release output is not empty: ${output_dir}" >&2
    exit 1
fi

install -d -m 0700 "${output_dir}"
output_dir=$(cd "${output_dir}" && pwd)
work_dir=$(mktemp -d "${repo_root}/target/.release-build.XXXXXX")
trap 'rm -rf -- "${work_dir}"' EXIT
install -d -m 0700 "${work_dir}/tmp"
export TMPDIR="${work_dir}/tmp"

signer=$(nix build "${repo_root}#initos-signer" --no-link --print-out-paths)
kernel=$(nix build "${repo_root}/linux#kernel-host" --no-link --print-out-paths)

SECRETS="${secrets_dir}" SIGNING_KEYS_REQUIRED=1 \
    "${signer}/bin/sign.sh" artifacts "${work_dir}/signed" \
    "${kernel}/opt/kernel-image" "${signer}"
printf '%s\n' "${revision}" > "${work_dir}/signed/img/revision"
if [ -n "${FIRMWARE_REVISION:-}" ]; then
    printf '%s\n' "${FIRMWARE_REVISION}" > "${work_dir}/signed/img/firmware.git-revision"
fi

tar -C "${work_dir}/signed/img" \
    --exclude='firmware*.erofs*' \
    -czf "${output_dir}/initos-signed-slot.tar.gz" .
(cd "${output_dir}" && sha256sum initos-signed-slot.tar.gz > SHA256SUMS)

printf 'signer=%s\nkernel=%s\nrelease=%s\n' \
    "${signer}" "${kernel}" "${output_dir}"
