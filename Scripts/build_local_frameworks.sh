#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ROOT="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
MODE="${LOCAL_FRAMEWORK_BUILD_MODE:-build}"

run_step() {
  local name="$1"
  local script="$2"
  local started
  local finished
  local elapsed

  echo "note: [Local Frameworks] Starting ${name} (${CONFIGURATION:-Debug})"
  started="$(date +%s)"

  if [[ "${MODE}" == "verify" ]]; then
    if PROJECT_DIR="${HOST_ROOT}" bash "${script}" --verify; then
      finished="$(date +%s)"
      elapsed="$((finished - started))"
      echo "note: [Local Frameworks] Finished ${name} in ${elapsed}s"
    else
      echo "error: [Local Frameworks] ${name} failed"
      return 1
    fi
  else
    if PROJECT_DIR="${HOST_ROOT}" bash "${script}"; then
      finished="$(date +%s)"
      elapsed="$((finished - started))"
      echo "note: [Local Frameworks] Finished ${name} in ${elapsed}s"
    else
      echo "error: [Local Frameworks] ${name} failed"
      return 1
    fi
  fi
}

if [[ "${SKIP_LOCAL_FRAMEWORK_BUILDS:-NO}" == "YES" ]]; then
  echo "note: [Local Frameworks] Skipping local framework build because SKIP_LOCAL_FRAMEWORK_BUILDS=YES"
  exit 0
fi

run_step "AVCMeterKit" "${SCRIPT_DIR}/build_avcmeterkit.sh"
run_step "AudioVisualiserConverterKit" "${SCRIPT_DIR}/build_audiovisualiserconverterkit.sh"
run_step "FireWireNetBridgeKit" "${SCRIPT_DIR}/build_firewirenetbridgekit.sh"

echo "note: [Local Frameworks] Ready"
