#!/usr/bin/env bash
set -euo pipefail

if [[ ! -e /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "skipping cloud-hypervisor VM test; /dev/kvm is not usable"
  exit 0
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"
cd "${PROJECT_ROOT}"

POD="${POD:-echoch}"
VM_STATE="${VM_STATE:-${PROJECT_ROOT}/target/vm/${POD}}"
SRC="${SRC:-${VM_STATE}/src}"
PROFILE="${PROFILE:-${PROJECT_ROOT}/target/vm/vm-cloud-profile}"
SERIAL_LOG="${VM_STATE}/run/serial.log"

rm -rf "${VM_STATE}/run" "${VM_STATE}/images" "${SRC}"
mkdir -p "${VM_STATE}/run" "${VM_STATE}/images" "${SRC}"

cat > "${SRC}/initos-pod" <<'EOF'
#!/opt/busybox/bin/sh
set -eu

case "${1:-start}" in
	  start)
	    echo "hi"
	    echo "hi" > /dev/kmsg 2>/dev/null || true
	    sync
	    sleep 300
    ;;
  *)
    echo "unsupported command: $1" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "${SRC}/initos-pod"

if [[ ! -x "${PROFILE}/bin/initos-vrun" ]]; then
  nix build "path:${PROJECT_ROOT}#vm-cloud-profile" -o "${PROFILE}"
fi

env POD="${POD}" SRC="${SRC}" WORK="${VM_STATE}/run" IMGDIR="${VM_STATE}/images" \
  vm_mem="${vm_mem:-1G}" vm_balloon="${vm_balloon:-256M}" NO_NET=1 SERIAL_LOG="${SERIAL_LOG}" \
  "${PROFILE}/bin/initos-vrun" start

stop_vm() {
  env POD="${POD}" WORK="${VM_STATE}/run" IMGDIR="${VM_STATE}/images" \
    PATH="${PROFILE}/bin:${PATH}" "${PROFILE}/bin/initos-vrun" stop
}

deadline=$((SECONDS + ${TIMEOUT:-90}))
while [[ $SECONDS -lt $deadline ]]; do
  if [[ -f "${SERIAL_LOG}" ]] && grep -q "hi" "${SERIAL_LOG}"; then
    stop_vm 2>/dev/null || true
    echo "cloud-hypervisor one-shot echo test passed"
    exit 0
  fi
  sleep 1
done

stop_vm 2>/dev/null || \
  env POD="${POD}" WORK="${VM_STATE}/run" IMGDIR="${VM_STATE}/images" \
    "${PROFILE}/bin/initos-vrun" vmkill 2>/dev/null || true
if [[ -f "${SERIAL_LOG}" ]]; then
  cat "${SERIAL_LOG}" >&2
fi
echo "cloud-hypervisor one-shot echo was not printed to the serial console" >&2
exit 1
