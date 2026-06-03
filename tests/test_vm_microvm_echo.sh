#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"
cd "${PROJECT_ROOT}"

FLAKE_DIR="${PROJECT_ROOT}/tests/microvm-echo"
WORK="${WORK:-${PROJECT_ROOT}/target/vm/microvm-echo}"
SHARE="${WORK}/share"
PROFILE="${PROFILE:-${PROJECT_ROOT}/target/vm/vm-cloud-profile}"
LOG="${WORK}/microvm.log"
STAMP="${WORK}/runner.sha256"

rm -rf "${SHARE}"
mkdir -p "${SHARE}/initos" "${WORK}"

cat > "${SHARE}/initos/initos-pod" <<'EOF'
#!/opt/busybox/bin/sh

case "${1:-start}" in
  start)
    echo "hi from microvm"
    echo "<6>hi from microvm" > /dev/kmsg 2>/dev/null || true
    sync
    /opt/busybox/bin/busybox poweroff -nf
    /opt/busybox/bin/busybox reboot -nf
    while true; do
      /opt/busybox/bin/busybox sleep 60
    done
    ;;
  *)
    echo "unsupported command: $1" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "${SHARE}/initos/initos-pod"

if [[ ! -x "${PROFILE}/bin/initos-vrun" ]]; then
  nix build "path:${PROJECT_ROOT}#vm-cloud-profile" -o "${PROFILE}"
fi
PROFILE_REAL="$(readlink -f "${PROFILE}")"

flake_hash="$(printf '%s\n' "${PROFILE_REAL}" "$(sha256sum "${FLAKE_DIR}/flake.nix" | awk '{print $1}')" | sha256sum | awk '{print $1}')"
if [[ ! -x "${WORK}/runner/bin/microvm-run" ]] || [[ ! -f "${STAMP}" ]] || [[ "$(cat "${STAMP}")" != "${flake_hash}" ]]; then
  rm -f "${WORK}/runner"
  nix build "path:${FLAKE_DIR}#runner" --override-input initosProfile "path:${PROFILE_REAL}" -o "${WORK}/runner"
  printf '%s\n' "${flake_hash}" > "${STAMP}"
fi

(
  cd "${FLAKE_DIR}"
  timeout --foreground "${TIMEOUT:-90}s" "${WORK}/runner/bin/microvm-run"
) 2>&1 | tee "${LOG}"

grep -q "hi from microvm" "${LOG}"
echo "microvm one-shot echo test passed"
