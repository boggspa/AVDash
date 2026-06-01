#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ROOT="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
FWNB_ROOT="${FIREWIRE_NET_BRIDGE_ROOT:-${HOST_ROOT}/../FireWireNetBridge}"
if [[ -d "${FWNB_ROOT}" ]]; then
  FWNB_ROOT="$(cd "${FWNB_ROOT}" && pwd)"
fi
FWNB_BUILD_DIR="${HOST_ROOT}/.firewirenetbridge-build"
FWNB_DERIVED_DATA_DIR="${HOST_ROOT}/.derivedData-firewirenetbridge"
FWNB_INTERMEDIATES_DIR="${FWNB_DERIVED_DATA_DIR}/Build/Intermediates.noindex"
FWNB_PRODUCTS_DIR="${FWNB_DERIVED_DATA_DIR}/Build/Products"
FWNB_CONFIGURATION="${CONFIGURATION:-Debug}"
FWNB_INSTALL_NAME="@rpath/FireWireNetBridgeKit.framework/Versions/A/FireWireNetBridgeKit"

# Keep the nested FireWireNetBridge build independent from the host scheme's odd Xcode
# environment so the framework build sees a normal developer directory.
unset XCODE_DEVELOPER_DIR_PATH
unset TOOLCHAINS
unset SWIFT_DEBUG_INFORMATION_FORMAT
unset SWIFT_DEBUG_INFORMATION_VERSION
unset IPHONEOS_DEPLOYMENT_TARGET
unset TVOS_DEPLOYMENT_TARGET
unset WATCHOS_DEPLOYMENT_TARGET
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

retry_remove_path() {
  local path="$1"
  local attempt

  if [[ ! -e "${path}" ]]; then
    return 0
  fi

  for attempt in 1 2 3 4 5; do
    /bin/rm -rf "${path}" 2>/dev/null || true
    if [[ ! -e "${path}" ]]; then
      return 0
    fi
    /bin/sleep 0.2
  done

  echo "Unable to remove ${path} after multiple attempts" >&2
  /bin/rm -rf "${path}"
}

trash_and_remove_path() {
  local path="$1"
  local trashed_path="${path}.stale.$$"

  if [[ ! -e "${path}" ]]; then
    return 0
  fi

  retry_remove_path "${trashed_path}"

  if /bin/mv "${path}" "${trashed_path}" 2>/dev/null; then
    retry_remove_path "${trashed_path}"
    return 0
  fi

  retry_remove_path "${path}"
}

normalize_install_name() {
  local framework_binary="${FWNB_BUILD_DIR}/FireWireNetBridgeKit.framework/FireWireNetBridgeKit"

  if [[ ! -f "${framework_binary}" ]]; then
    return 0
  fi

  local current_id
  current_id="$(/usr/bin/otool -D "${framework_binary}" | sed -n '2p' | tr -d '[:space:]')"
  if [[ "${current_id}" == "${FWNB_INSTALL_NAME}" ]]; then
    return 0
  fi

  echo "Rewriting FireWireNetBridgeKit install name: ${current_id} -> ${FWNB_INSTALL_NAME}"
  /usr/bin/install_name_tool -id "${FWNB_INSTALL_NAME}" "${framework_binary}"
}

rewrite_module_map() {
  local module_map="${FWNB_BUILD_DIR}/FireWireNetBridgeKit.framework/Modules/module.modulemap"

  if [[ ! -f "${module_map}" ]]; then
    return 0
  fi

  if /usr/bin/grep -q 'header "../Headers/FireWireNetBridgeKit-Swift.h"' "${module_map}"; then
    return 0
  fi

  echo "Rewriting FireWireNetBridgeKit module map header path"
  /usr/bin/perl -0pi -e 's#header "FireWireNetBridgeKit-Swift.h"#header "../Headers/FireWireNetBridgeKit-Swift.h"#g' "${module_map}"
}

seed_swift_header() {
  local source_header=""
  local candidate_configuration=""

  for candidate_configuration in "${FWNB_CONFIGURATION}" Debug Release; do
    for candidate in \
      "${FWNB_DERIVED_DATA_DIR}/Build/Intermediates.noindex/FireWireNetBridge.build/${candidate_configuration}/FireWireNetBridgeKit.build/Objects-normal/arm64/FireWireNetBridgeKit-Swift.h" \
      "${FWNB_DERIVED_DATA_DIR}/Build/Intermediates.noindex/FireWireNetBridge.build/${candidate_configuration}/FireWireNetBridgeKit.build/Objects-normal/x86_64/FireWireNetBridgeKit-Swift.h" \
      "${FWNB_ROOT}/build/FireWireNetBridge.build/${candidate_configuration}/FireWireNetBridgeKit.build/Objects-normal/arm64/FireWireNetBridgeKit-Swift.h"; do
      if [[ -f "${candidate}" ]]; then
        source_header="${candidate}"
        break 2
      fi
    done
  done

  if [[ -z "${source_header}" ]]; then
    return 0
  fi

  local dest_header="${FWNB_BUILD_DIR}/FireWireNetBridgeKit.framework/Headers/FireWireNetBridgeKit-Swift.h"
  mkdir -p "$(dirname "${dest_header}")"

  if [[ -f "${dest_header}" ]] && /usr/bin/cmp -s "${source_header}" "${dest_header}"; then
    return 0
  fi

  echo "Seeding FireWireNetBridgeKit Swift header from ${source_header}"
  /usr/bin/ditto "${source_header}" "${dest_header}"
}

copy_driver_and_sender() {
  # Copy the driver and sender CLI to the build directory for easy installation
  local driver_source="${FWNB_PRODUCTS_DIR}/${FWNB_CONFIGURATION}/FireWireNetBridgeDriver.driver"
  local sender_source="${FWNB_PRODUCTS_DIR}/${FWNB_CONFIGURATION}/FireWireNetBridgeSender"

  if [[ -d "${driver_source}" ]]; then
    echo "Copying FireWireNetBridgeDriver.driver to build directory"
    /usr/bin/ditto "${driver_source}" "${FWNB_BUILD_DIR}/FireWireNetBridgeDriver.driver"
  fi

  if [[ -f "${sender_source}" ]]; then
    echo "Copying FireWireNetBridgeSender CLI to build directory"
    /usr/bin/ditto "${sender_source}" "${FWNB_BUILD_DIR}/FireWireNetBridgeSender"
  fi
}

echo "Building FireWireNetBridgeKit.framework (${FWNB_CONFIGURATION})"

if [[ "${1:-}" != "--verify" ]]; then
  trash_and_remove_path "${FWNB_BUILD_DIR}"
  trash_and_remove_path "${FWNB_DERIVED_DATA_DIR}/Build"
  trash_and_remove_path "${FWNB_DERIVED_DATA_DIR}/Index.noindex"
  trash_and_remove_path "${FWNB_DERIVED_DATA_DIR}/ModuleCache.noindex"
  trash_and_remove_path "${FWNB_DERIVED_DATA_DIR}/SDKStatCaches.noindex"
fi

mkdir -p "${FWNB_BUILD_DIR}" "${FWNB_INTERMEDIATES_DIR}" "${FWNB_PRODUCTS_DIR}"

if [[ "${1:-}" == "--verify" ]]; then
  if [[ -d "${FWNB_BUILD_DIR}/FireWireNetBridgeKit.framework" ]]; then
    normalize_install_name
    echo "Using prebuilt FireWireNetBridgeKit.framework at ${FWNB_BUILD_DIR}"
    exit 0
  fi

  echo "FireWireNetBridgeKit.framework is missing at ${FWNB_BUILD_DIR}"
  echo "Run: bash \"${HOST_ROOT}/Scripts/build_firewirenetbridgekit.sh\""
  exit 1
fi

# Build the framework
env -i \
  HOME="${HOME}" \
  LOGNAME="${LOGNAME:-$(id -un)}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin" \
  TMPDIR="${TMPDIR:-/tmp}" \
  USER="${USER:-$(id -un)}" \
  DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  xcodebuild \
    -project "${FWNB_ROOT}/FireWireNetBridge.xcodeproj" \
    -scheme FireWireNetBridge \
    -configuration "${FWNB_CONFIGURATION}" \
    -derivedDataPath "${FWNB_DERIVED_DATA_DIR}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    -disableAutomaticPackageResolution \
    SYMROOT="${FWNB_PRODUCTS_DIR}" \
    OBJROOT="${FWNB_INTERMEDIATES_DIR}" \
    CONFIGURATION_BUILD_DIR="${FWNB_BUILD_DIR}" \
    build

normalize_install_name
rewrite_module_map
seed_swift_header
copy_driver_and_sender

echo ""
echo "FireWireNetBridgeKit build complete at: ${FWNB_BUILD_DIR}"
echo "  - Framework: ${FWNB_BUILD_DIR}/FireWireNetBridgeKit.framework"
echo "  - Driver: ${FWNB_BUILD_DIR}/FireWireNetBridgeDriver.driver"
echo "  - Sender CLI: ${FWNB_BUILD_DIR}/FireWireNetBridgeSender"
