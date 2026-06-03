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
    ;;
  *)
    echo "unsupported command: $1" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "${SRC}/initos-pod"

nix build "path:${PROJECT_ROOT}#vm-cloud-profile" -o "${PROFILE}"

env POD="${POD}" SRC="${SRC}" WORK="${VM_STATE}/run" IMGDIR="${VM_STATE}/images" \
  vm_mem="${vm_mem:-512M}" vm_cpu="${vm_cpu:-1}" vm_balloon="${vm_balloon:-0}" NO_NET=1 SERIAL_LOG="${SERIAL_LOG}" \
  "${PROFILE}/bin/initos-vrun" start

deadline=$((SECONDS + ${TIMEOUT:-90}))
printed=0
while [[ $SECONDS -lt $deadline ]]; do
  if [[ -f "${SERIAL_LOG}" ]] && tr -d '\r' < "${SERIAL_LOG}" | grep -qx "hi"; then
    printed=1
    break
  fi
  sleep 0.1
done

if [[ "${printed}" != 1 ]]; then
  env POD="${POD}" WORK="${VM_STATE}/run" IMGDIR="${VM_STATE}/images" \
    "${PROFILE}/bin/initos-vrun" vmkill 2>/dev/null || true
  if [[ -f "${SERIAL_LOG}" ]]; then
    cat "${SERIAL_LOG}" >&2
  fi
  echo "cloud-hypervisor one-shot echo was not printed to the serial console" >&2
  exit 1
fi

pid_file="${VM_STATE}/run/vm.pid"
if [[ -f "${pid_file}" ]]; then
  vm_pid="$(cat "${pid_file}")"
  exit_deadline=$((SECONDS + 10))
  while [[ $SECONDS -lt $exit_deadline ]] && kill -0 "${vm_pid}" 2>/dev/null; do
    sleep 0.1
  done
  if kill -0 "${vm_pid}" 2>/dev/null; then
    echo "cloud-hypervisor did not exit after guest poweroff" >&2
    env POD="${POD}" WORK="${VM_STATE}/run" IMGDIR="${VM_STATE}/images" \
      "${PROFILE}/bin/initos-vrun" vmkill 2>/dev/null || true
    exit 1
  fi
fi

rm -f "${VM_STATE}/run/vm.pid" "${VM_STATE}/run/virtiofsd.pid" "${VM_STATE}/run/virtiofs.sock.pid"
rm -f "${VM_STATE}/run/ch.sock" "${VM_STATE}/run/serial.socket" "${VM_STATE}/run/virtiofs.sock"

echo "cloud-hypervisor one-shot echo test passed"
