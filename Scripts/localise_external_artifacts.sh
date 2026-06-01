#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_PATH=""
ARTIFACTS_DIR="${EXTERNAL_ARTIFACTS_DIR:-${REPO_ROOT}/Artifacts/External}"
SIGNING_IDENTITY="${DEVELOPER_ID_IDENTITY:-}"
WORK_DIR="${BUILD_ROOT:-${REPO_ROOT}/build/ReleaseDMG}/ExternalArtifactSigning"
ALLOW_UNSIGNED="${ALLOW_UNSIGNED_EXTERNAL_ARTIFACTS:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") --app-path PATH --signing-identity ID [options]

Copies external release payloads into an exported app, verifies their existing
signatures, preserves or reapplies entitlements, and signs copied code deepest
first. The caller must re-sign the host app after this script completes.

Options:
  --app-path PATH        Exported .app bundle to modify.
  --artifacts-dir PATH   External artifact root. Default: ${ARTIFACTS_DIR}
  --signing-identity ID  Developer ID Application identity hash or name.
  --work-dir PATH        Temporary entitlement extraction directory.
                         Default: ${WORK_DIR}
  --allow-unsigned       Permit unsigned Mach-O payloads and sign them without
                         preserved entitlements. Intended for local experiments.
  -h, --help             Show this help.

Supported artifact layout:
  Artifacts/External/
    Frameworks/*.framework              -> Contents/Frameworks/
    PlugIns/*.{appex,plugin,bundle}     -> Contents/PlugIns/
    XPCServices/*.xpc                   -> Contents/XPCServices/
    Library/LaunchServices/*            -> Contents/Library/LaunchServices/
    Audio/Plug-Ins/HAL/*.{driver,plugin}-> Contents/Library/Audio/Plug-Ins/HAL/
    Resources/*                         -> Contents/Resources/

Optional entitlement overrides:
  Artifacts/External/Entitlements/<Contents-relative-path>.plist
  Artifacts/External/Entitlements/<artifact-basename>.plist

Examples:
  Artifacts/External/Entitlements/Frameworks/AVCMeterKit.framework.plist
  Artifacts/External/Entitlements/FireWireNetBridgeSender.plist
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-path)
      APP_PATH="$2"
      shift
      ;;
    --artifacts-dir)
      ARTIFACTS_DIR="$2"
      shift
      ;;
    --signing-identity)
      SIGNING_IDENTITY="$2"
      shift
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift
      ;;
    --allow-unsigned)
      ALLOW_UNSIGNED=1
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

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "--app-path must point to an exported .app bundle." >&2
  exit 2
fi

if [[ -z "${SIGNING_IDENTITY}" ]]; then
  echo "--signing-identity is required." >&2
  exit 2
fi

USE_TIMESTAMP=1
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
  USE_TIMESTAMP=0
fi

if [[ ! -d "${ARTIFACTS_DIR}" ]]; then
  echo "External artifacts directory does not exist: ${ARTIFACTS_DIR}" >&2
  exit 1
fi

/bin/mkdir -p "${WORK_DIR}"
ENTITLEMENTS_MAP="${WORK_DIR}/external-entitlements.tsv"
: > "${ENTITLEMENTS_MAP}"

COPIED_LIST="${WORK_DIR}/copied-roots.txt"
SIGNABLE_LIST="${WORK_DIR}/signable-items.txt"
SORTED_SIGNABLE_LIST="${WORK_DIR}/signable-items-sorted.txt"
: > "${COPIED_LIST}"
: > "${SIGNABLE_LIST}"
: > "${SORTED_SIGNABLE_LIST}"

copy_artifact() {
  local source="$1"
  local destination="$2"
  local label="$3"

  echo "Embedding ${label}: ${source}"
  /bin/rm -rf "${destination}"
  /bin/mkdir -p "$(dirname "${destination}")"
  /usr/bin/ditto "${source}" "${destination}"
  printf '%s\n' "${destination}" >> "${COPIED_LIST}"
}

copy_directory_children() {
  local source_dir="$1"
  local destination_dir="$2"
  local label="$3"
  shift 3

  [[ -d "${source_dir}" ]] || return 0
  /bin/mkdir -p "${destination_dir}"

  while IFS= read -r source; do
    copy_artifact "${source}" "${destination_dir}/$(basename "${source}")" "${label}"
  done < <(/usr/bin/find "${source_dir}" "$@" -print | sort)
}

copy_supported_payloads() {
  copy_directory_children \
    "${ARTIFACTS_DIR}/Frameworks" \
    "${APP_PATH}/Contents/Frameworks" \
    "external framework" \
    -maxdepth 1 -type d -name "*.framework"

  copy_directory_children \
    "${ARTIFACTS_DIR}/PlugIns" \
    "${APP_PATH}/Contents/PlugIns" \
    "external plug-in" \
    -maxdepth 1 -type d \( -name "*.appex" -o -name "*.plugin" -o -name "*.bundle" \)

  copy_directory_children \
    "${ARTIFACTS_DIR}/XPCServices" \
    "${APP_PATH}/Contents/XPCServices" \
    "external XPC service" \
    -maxdepth 1 -type d -name "*.xpc"

  copy_directory_children \
    "${ARTIFACTS_DIR}/Library/LaunchServices" \
    "${APP_PATH}/Contents/Library/LaunchServices" \
    "external helper tool" \
    -maxdepth 1 -mindepth 1

  copy_directory_children \
    "${ARTIFACTS_DIR}/Audio/Plug-Ins/HAL" \
    "${APP_PATH}/Contents/Library/Audio/Plug-Ins/HAL" \
    "external HAL payload" \
    -maxdepth 1 -type d \( -name "*.driver" -o -name "*.plugin" \)

  copy_directory_children \
    "${ARTIFACTS_DIR}/Resources" \
    "${APP_PATH}/Contents/Resources" \
    "external resource" \
    -mindepth 1 -maxdepth 1
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
  local relative="${item#${APP_PATH}/Contents/}"
  local candidate

  candidate="${ARTIFACTS_DIR}/Entitlements/${relative}.plist"
  if [[ -f "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  candidate="${ARTIFACTS_DIR}/Entitlements/$(basename "${item}").plist"
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

  get_task_allow="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "${entitlement_file}" 2>/dev/null || true)"
  if [[ "${get_task_allow}" == "true" ]]; then
    echo "Refusing to preserve debug entitlement com.apple.security.get-task-allow for: ${item}" >&2
    echo "Provide a release entitlement override under ${ARTIFACTS_DIR}/Entitlements/ without get-task-allow." >&2
    exit 1
  fi
}

verify_existing_signature() {
  local item="$1"

  if /usr/bin/codesign --verify --strict --verbose=2 "${item}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${ALLOW_UNSIGNED}" == "1" ]]; then
    echo "warning: ${item} is not signed; signing without preserved entitlements." >&2
    return 0
  fi

  echo "External code is not validly signed before localisation: ${item}" >&2
  echo "Sign the source artifact first, or rerun with --allow-unsigned for local experiments." >&2
  exit 1
}

record_entitlements_for_item() {
  local item="$1"
  local entitlement_file=""
  local override
  local hash

  if override="$(entitlements_override_for_item "${item}")"; then
    /usr/bin/plutil -lint "${override}" >/dev/null
    entitlement_file="${override}"
  else
    hash="$(printf '%s' "${item}" | /usr/bin/shasum -a 256 | /usr/bin/awk '{ print $1 }')"
    entitlement_file="${WORK_DIR}/${hash}.entitlements.plist"
    if ! /usr/bin/codesign -d --entitlements :- "${item}" > "${entitlement_file}" 2>/dev/null; then
      entitlement_file=""
    elif [[ ! -s "${entitlement_file}" ]]; then
      /bin/rm -f "${entitlement_file}"
      entitlement_file=""
    elif ! /usr/bin/plutil -lint "${entitlement_file}" >/dev/null 2>&1; then
      /bin/rm -f "${entitlement_file}"
      entitlement_file=""
    fi
  fi

  validate_entitlements_for_release "${item}" "${entitlement_file}"
  printf '%s\t%s\n' "${item}" "${entitlement_file}" >> "${ENTITLEMENTS_MAP}"
}

record_existing_signatures_and_entitlements() {
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    verify_existing_signature "${item}"
    record_entitlements_for_item "${item}"
  done < "${SIGNABLE_LIST}"
}

entitlements_for_item() {
  local item="$1"
  /usr/bin/awk -F '\t' -v key="${item}" '$1 == key { print $2; exit }' "${ENTITLEMENTS_MAP}"
}

sign_item() {
  local item="$1"
  local entitlements
  local args

  entitlements="$(entitlements_for_item "${item}")"
  args=(--force)
  if [[ "${USE_TIMESTAMP}" == "1" ]]; then
    args+=(--timestamp)
  fi
  args+=(--options runtime --sign "${SIGNING_IDENTITY}")
  if [[ -n "${entitlements}" ]]; then
    args+=(--entitlements "${entitlements}")
  fi

  echo "Signing external code: ${item}"
  /usr/bin/codesign "${args[@]}" "${item}"
  /usr/bin/codesign --verify --strict --verbose=2 "${item}" >/dev/null
}

sign_external_code_deepest_first() {
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    sign_item "${item}"
  done < "${SORTED_SIGNABLE_LIST}"
}

verify_copied_roots() {
  while IFS= read -r item; do
    [[ -n "${item}" ]] || continue
    /usr/bin/codesign --verify --strict --verbose=2 "${item}" >/dev/null
  done < "${SORTED_SIGNABLE_LIST}"
}

copy_supported_payloads

if [[ ! -s "${COPIED_LIST}" ]]; then
  echo "warning: no supported external payloads found in ${ARTIFACTS_DIR}" >&2
  exit 0
fi

collect_signable_items
record_existing_signatures_and_entitlements
sign_external_code_deepest_first
verify_copied_roots

echo "External artifacts localised into ${APP_PATH}"
