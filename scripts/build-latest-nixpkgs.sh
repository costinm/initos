#!/usr/bin/env bash
#
# Refresh Nixpkgs in this checkout and build against the refreshed locks.
# Intended for CI probes where the lock-file changes are not committed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

build=true
targets=()

usage() {
    cat <<'USAGE'
Usage: scripts/build-latest-nixpkgs.sh [OPTIONS] [TARGET...]

Updates flake.lock to the latest versions of all root inputs, aligns
linux/flake.lock to the root lock, and builds the requested targets. If no
targets are supplied, this builds:

  .#initos-signer
  ./linux#kernel-host
  ./linux#nvidia-compute
  .#initos-host
  .#docker-image

Options:
  --no-build     Refresh locks only.
  -h, --help     Show this help.

The script modifies flake.lock and linux/flake.lock in the current checkout.
CI can run it without committing those changes.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-build)
            build=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            targets+=("$@")
            break
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            targets+=("$1")
            ;;
    esac
    shift
done

if [ "${#targets[@]}" -eq 0 ]; then
    targets=(
        ".#initos-signer"
        "./linux#kernel-host"
        "./linux#nvidia-compute"
        ".#initos-host"
        ".#docker-image"
    )
fi

nix flake update

"${SCRIPT_DIR}/build.sh" align_flake_locks

echo "Root nixpkgs lock:"
nix flake metadata --json \
    | sed -n 's/.*"nixpkgs":{"locked":{[^}]*"rev":"\([^"]*\)".*/  rev: \1/p'

if "${build}"; then
    nix build --no-link --print-build-logs "${targets[@]}"
fi
