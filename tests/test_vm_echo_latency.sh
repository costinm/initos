#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -P "${SCRIPT_DIR}/.." && pwd -P)"
cd "${PROJECT_ROOT}"

OUT="${OUT:-${PROJECT_ROOT}/target/vm/echo-latency}"
LOG_DIR="${OUT}/logs"
mkdir -p "${LOG_DIR}"

tests=(
  "qemu-vrun"
  "cloud-hypervisor-vrun"
  "crosvm-vrun"
  "microvm-crosvm"
  "microvm-qemu"
  "microvm-cloud-hypervisor"
)

run_one() {
  local name="$1"
  local log="${LOG_DIR}/${name}.log"
  local start_ns
  local end_ns
  local status
  local elapsed_ms

  printf 'running %-26s' "${name}"
  start_ns="$(date +%s%N)"
  case "${name}" in
    qemu-vrun)
      TIMEOUT="${TIMEOUT:-90}" tests/test_vm_qemu_echo.sh >"${log}" 2>&1
      ;;
    cloud-hypervisor-vrun)
      TIMEOUT="${TIMEOUT:-90}" tests/test_vm_vrun_cloud_hypervisor_echo.sh >"${log}" 2>&1
      ;;
    crosvm-vrun)
      TIMEOUT="${TIMEOUT:-90}" tests/test_vm_vrun_crosvm_echo.sh >"${log}" 2>&1
      ;;
    microvm-crosvm)
      TIMEOUT="${TIMEOUT:-90}" MICROVM_HYPERVISOR=crosvm tests/test_vm_microvm_echo.sh >"${log}" 2>&1
      ;;
    microvm-qemu)
      TIMEOUT="${TIMEOUT:-90}" MICROVM_HYPERVISOR=qemu tests/test_vm_microvm_echo.sh >"${log}" 2>&1
      ;;
    microvm-cloud-hypervisor)
      TIMEOUT="${TIMEOUT:-90}" MICROVM_HYPERVISOR=cloud-hypervisor tests/test_vm_microvm_echo.sh >"${log}" 2>&1
      ;;
    *)
      echo "unknown test: ${name}" >&2
      return 2
      ;;
  esac
  status=$?
  end_ns="$(date +%s%N)"
  elapsed_ms=$(((end_ns - start_ns) / 1000000))

  if [[ "${status}" -eq 0 ]]; then
    printf ' ok %s ms\n' "${elapsed_ms}"
  else
    printf ' fail %s ms\n' "${elapsed_ms}"
  fi

  printf '%s\t%s\t%s\t%s\n' "${name}" "${status}" "${elapsed_ms}" "${log}" >> "${OUT}/results.tsv"
  return 0
}

rm -f "${OUT}/results.tsv"
printf 'name\tstatus\tms\tlog\n' > "${OUT}/results.tsv"

for name in "${tests[@]}"; do
  run_one "${name}"
done

echo
printf '%-28s %-8s %10s %s\n' "name" "status" "ms" "log"
tail -n +2 "${OUT}/results.tsv" | while IFS=$'\t' read -r name status elapsed_ms log; do
  if [[ "${status}" -eq 0 ]]; then
    status_text="ok"
  else
    status_text="fail:${status}"
  fi
  printf '%-28s %-8s %10s %s\n' "${name}" "${status_text}" "${elapsed_ms}" "${log}"
done
