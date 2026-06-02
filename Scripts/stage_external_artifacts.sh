#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-8CZML8FK2D}"
EXTERNAL_ARTIFACTS_DIR="${EXTERNAL_ARTIFACTS_DIR:-${REPO_ROOT}/Artifacts/External}"
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-}"
SKIP_BUILD=0
CLEAN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Builds local sibling products, stages them into Artifacts/External, and signs
the staged payloads for release packaging.

Options:
  --clean       Remove previously staged known payloads before copying.
  --skip-build  Stage from existing local build outputs.
  -h, --help    Show this help.

Environment:
  CONFIGURATION             build configuration, default: ${CONFIGURATION}
  TEAM_ID                   Apple Developer Team ID, default: ${TEAM_ID}
  DEVELOPER_ID_IDENTITY     Developer ID Application identity hash or name.
                            If omitted, the first identity for TEAM_ID is used.
  EXTERNAL_ARTIFACTS_DIR    staging root, default: ${EXTERNAL_ARTIFACTS_DIR}
  AVCMETER_ROOT             optional sibling checkout path.
  AUDIO_VISUALISER_ROOT     optional sibling checkout path.
  FIREWIRE_NET_BRIDGE_ROOT  optional sibling checkout path.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN=1
      ;;
    --skip-build)
      SKIP_BUILD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

resolve_developer_id_identity() {
  if [[ -n "${DEVELOPER_ID_IDENTITY}" ]]; then
    echo "${DEVELOPER_ID_IDENTITY}"
    return 0
  fi

  local identities
  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep "Developer ID Application: .*(${TEAM_ID})" || true)"
  local identity_count
  identity_count="$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' <<< "${identities}")"

  if [[ "${identity_count}" -eq 0 ]]; then
    echo "Could not find a Developer ID Application identity for team ${TEAM_ID}." >&2
    exit 1
  fi

  if [[ "${identity_count}" -gt 1 ]]; then
    echo "Multiple Developer ID Application identities found for team ${TEAM_ID}; using the first valid identity." >&2
  fi

  /usr/bin/awk 'NF { print $2; exit }' <<< "${identities}"
}

SIGNING_IDENTITY="$(resolve_developer_id_identity)"
WORK_DIR="${EXTERNAL_ARTIFACTS_DIR}/.staging-signing"
COPIED_LIST="${WORK_DIR}/copied-roots.txt"
SIGNABLE_LIST="${WORK_DIR}/signable-items.txt"
SORTED_SIGNABLE_LIST="${WORK_DIR}/signable-items-sorted.txt"

reset_known_payloads() {
  /bin/rm -rf \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/AVCMeterKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/AudioVisualiserConverterKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/FireWireNetBridgeKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Audio/Plug-Ins/HAL/FireWireNetBridgeDriver.driver" \
    "${EXTERNAL_ARTIFACTS_DIR}/Resources/FireWireNetBridgeSender"
}

run_local_builds() {
  if [[ "${SKIP_BUILD}" == "1" ]]; then
    echo "Skipping sibling builds; staging existing local build outputs."
    return 0
  fi

  echo "Building local sibling artifacts (${CONFIGURATION})"
  CONFIGURATION="${CONFIGURATION}" PROJECT_DIR="${REPO_ROOT}" "${SCRIPT_DIR}/build_avcmeterkit.sh"
  CONFIGURATION="${CONFIGURATION}" PROJECT_DIR="${REPO_ROOT}" "${SCRIPT_DIR}/build_audiovisualiserconverterkit.sh"
  CONFIGURATION="${CONFIGURATION}" PROJECT_DIR="${REPO_ROOT}" "${SCRIPT_DIR}/build_firewirenetbridgekit.sh"
}

copy_artifact() {
  local source="$1"
  local destination="$2"
  local label="$3"

  if [[ ! -e "${source}" ]]; then
    echo "Missing ${label}: ${source}" >&2
    exit 1
  fi

  echo "Staging ${label}: ${destination}"
  /bin/rm -rf "${destination}"
  /bin/mkdir -p "$(dirname "${destination}")"
  /usr/bin/ditto "${source}" "${destination}"
  printf '%s\n' "${destination}" >> "${COPIED_LIST}"
}

stage_known_payloads() {
  copy_artifact \
    "${REPO_ROOT}/.avcmeterkit-build/AVCMeterKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/AVCMeterKit.framework" \
    "AVCMeterKit.framework"

  copy_artifact \
    "${REPO_ROOT}/.audiovisualiserkit-build/AudioVisualiserConverterKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/AudioVisualiserConverterKit.framework" \
    "AudioVisualiserConverterKit.framework"

  copy_artifact \
    "${REPO_ROOT}/.firewirenetbridge-build/FireWireNetBridgeKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/FireWireNetBridgeKit.framework" \
    "FireWireNetBridgeKit.framework"

  copy_artifact \
    "${REPO_ROOT}/.firewirenetbridge-build/FireWireNetBridgeDriver.driver" \
    "${EXTERNAL_ARTIFACTS_DIR}/Audio/Plug-Ins/HAL/FireWireNetBridgeDriver.driver" \
    "FireWireNetBridgeDriver.driver"

  copy_artifact \
    "${REPO_ROOT}/.firewirenetbridge-build/FireWireNetBridgeSender" \
    "${EXTERNAL_ARTIFACTS_DIR}/Resources/FireWireNetBridgeSender" \
    "FireWireNetBridgeSender"
}

path_is_inside_code_bundle() {
  local path="$1"
  [[ "${path}" =~ \.(app|appex|framework|xpc|plugin|driver|bundle)/ ]]
}

is_macho_file() {
  local path="$1"
  [[ -f "${path}" ]] || return 1
  /usr/bin/file -b "${path}" | /usr/bin/grep -Eq 'Mach-O'
}

collect_signable_items_for_root() {
  local root="$1"

  if [[ -d "${root}" ]]; then
    /usr/bin/find "${root}" -type d \( \
      -name "*.app" -o \
      -name "*.appex" -o \
      -name "*.framework" -o \
      -name "*.xpc" -o \
      -name "*.plugin" -o \
      -name "*.driver" -o \
      -name "*.bundle" \
    \) -print

    while IFS= read -r file; do
      if path_is_inside_code_bundle "${file}"; then
        continue
      fi
      if is_macho_file "${file}"; then
        printf '%s\n' "${file}"
      fi
    done < <(/usr/bin/find "${root}" -type f -perm -111 -print)
  elif is_macho_file "${root}"; then
    printf '%s\n' "${root}"
  fi
}

collect_signable_items() {
  while IFS= read -r root; do
    collect_signable_items_for_root "${root}"
  done < "${COPIED_LIST}" | /usr/bin/sort -u > "${SIGNABLE_LIST}"

  /usr/bin/perl -ne 'chomp; $depth = ($_ =~ tr{/}{}); print "$depth\t", length($_), "\t$_\n"' "${SIGNABLE_LIST}" \
    | /usr/bin/sort -r -n -k1,1 -k2,2 \
    | /usr/bin/cut -f3- > "${SORTED_SIGNABLE_LIST}"
}

entitlements_override_for_item() {
  local item="$1"
  local relative="${item#${EXTERNAL_ARTIFACTS_DIR}/}"
  local candidate

  candidate="${EXTERNAL_ARTIFACTS_DIR}/Entitlements/${relative}.plist"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  candidate="${EXTERNAL_ARTIFACTS_DIR}/Entitlements/$(basename "${item}").plist"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

validate_entitlements_for_release() {
  local item="$1"
  local entitlement_file="$2"
  local get_task_allow

  [[ -n "${entitlement_file}" ]] || return 0

  /usr/bin/plutil -lint "${entitlement_file}" >/dev/null
  get_task_allow="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "${entitlement_file}" 2>/dev/null || true)"
  if [[ "${get_task_allow}" == "true" ]]; then
    echo "Refusing to sign debug entitlement com.apple.security.get-task-allow for: ${item}" >&2
    exit 1
  fi
}

sign_item() {
  local item="$1"
  local entitlements=""
  local args

  if entitlements="$(entitlements_override_for_item "${item}")"; then
    validate_entitlements_for_release "${item}" "${entitlements}"
  else
    entitlements=""
  fi

  args=(--force --timestamp --options runtime --sign "${SIGNING_IDENTITY}")
  if [[ -n "${entitlements}" ]]; then
    args+=(--entitlements "${entitlements}")
  fi

  echo "Signing staged external code: ${item}"
  /usr/bin/codesign "${args[@]}" "${item}"
  /usr/bin/codesign --verify --strict --verbose=2 "${item}" >/dev/null
}

sign_external_code_deepest_first() {
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    sign_item "${item}"
  done < "${SORTED_SIGNABLE_LIST}"
}

verify_archs_for_binary() {
  local label="$1"
  local binary="$2"
  local archs

  archs="$(/usr/bin/lipo -archs "${binary}" 2>/dev/null || true)"
  if [[ "${archs}" != *"arm64"* || "${archs}" != *"x86_64"* ]]; then
    echo "${label} is not universal arm64/x86_64: ${archs}" >&2
    exit 1
  fi
}

verify_staged_payloads() {
  verify_archs_for_binary \
    "AVCMeterKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/AVCMeterKit.framework/Versions/A/AVCMeterKit"
  verify_archs_for_binary \
    "AudioVisualiserConverterKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/AudioVisualiserConverterKit.framework/Versions/A/AudioVisualiserConverterKit"
  verify_archs_for_binary \
    "FireWireNetBridgeKit.framework" \
    "${EXTERNAL_ARTIFACTS_DIR}/Frameworks/FireWireNetBridgeKit.framework/Versions/A/FireWireNetBridgeKit"
  verify_archs_for_binary \
    "FireWireNetBridgeDriver.driver" \
    "${EXTERNAL_ARTIFACTS_DIR}/Audio/Plug-Ins/HAL/FireWireNetBridgeDriver.driver/Contents/MacOS/FireWireNetBridgeDriver"
  verify_archs_for_binary \
    "FireWireNetBridgeSender" \
    "${EXTERNAL_ARTIFACTS_DIR}/Resources/FireWireNetBridgeSender"

  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    /usr/bin/codesign --verify --strict --verbose=2 "${item}" >/dev/null
  done < "${SORTED_SIGNABLE_LIST}"
}

if [[ "${CLEAN}" == "1" ]]; then
  reset_known_payloads
fi

/bin/mkdir -p "${WORK_DIR}"
: > "${COPIED_LIST}"
: > "${SIGNABLE_LIST}"
: > "${SORTED_SIGNABLE_LIST}"

run_local_builds
stage_known_payloads
collect_signable_items
sign_external_code_deepest_first
verify_staged_payloads

echo "External artifacts staged and signed in ${EXTERNAL_ARTIFACTS_DIR}"
