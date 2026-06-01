#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ROOT="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
AVC_ROOT="${AVCMETER_ROOT:-${HOST_ROOT}/../AVCMeter}"
if [[ -d "${AVC_ROOT}" ]]; then
  AVC_ROOT="$(cd "${AVC_ROOT}" && pwd)"
fi
AVC_BUILD_DIR="${HOST_ROOT}/.avcmeterkit-build"
AVC_DERIVED_DATA_DIR="${HOST_ROOT}/.derivedData-avcmeterkit"
AVC_INTERMEDIATES_DIR="${AVC_DERIVED_DATA_DIR}/Build/Intermediates.noindex"
AVC_PRODUCTS_DIR="${AVC_DERIVED_DATA_DIR}/Build/Products"
AVC_CONFIGURATION="${CONFIGURATION:-Debug}"
AVC_INSTALL_NAME="@rpath/AVCMeterKit.framework/Versions/A/AVCMeterKit"

# Keep the nested AVCMeterKit build independent from the host scheme's odd Xcode
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
  local framework_binary="${AVC_BUILD_DIR}/AVCMeterKit.framework/AVCMeterKit"

  if [[ ! -f "${framework_binary}" ]]; then
    return 0
  fi

  local current_id
  current_id="$(/usr/bin/otool -D "${framework_binary}" | sed -n '2p' | tr -d '[:space:]')"
  if [[ "${current_id}" == "${AVC_INSTALL_NAME}" ]]; then
    return 0
  fi

  echo "Rewriting AVCMeterKit install name: ${current_id} -> ${AVC_INSTALL_NAME}"
  /usr/bin/install_name_tool -id "${AVC_INSTALL_NAME}" "${framework_binary}"
}

rewrite_module_map() {
  local module_map="${AVC_BUILD_DIR}/AVCMeterKit.framework/Modules/module.modulemap"

  if [[ ! -f "${module_map}" ]]; then
    return 0
  fi

  if /usr/bin/grep -q 'header "../Headers/AVCMeterKit-Swift.h"' "${module_map}"; then
    return 0
  fi

  echo "Rewriting AVCMeterKit module map header path"
  /usr/bin/perl -0pi -e 's#header "AVCMeterKit-Swift.h"#header "../Headers/AVCMeterKit-Swift.h"#g' "${module_map}"
}

seed_source_packages() {
  local seeded_source_packages=""
  for candidate in "${HOME}"/Library/Developer/Xcode/DerivedData/AVCMeter-*/SourcePackages; do
    if [[ -d "${candidate}/checkouts/swift-atomics" ]]; then
      seeded_source_packages="${candidate}"
      break
    fi
  done

  if [[ -z "${seeded_source_packages}" ]]; then
    return 0
  fi

  if [[ -d "${AVC_DERIVED_DATA_DIR}/SourcePackages/checkouts/swift-atomics" ]]; then
    return 0
  fi

  echo "Seeding AVCMeterKit SwiftPM cache from ${seeded_source_packages}"
  rm -rf "${AVC_DERIVED_DATA_DIR}/SourcePackages"
  /usr/bin/ditto "${seeded_source_packages}" "${AVC_DERIVED_DATA_DIR}/SourcePackages"
}

seed_metal_artifacts() {
  local source_metal_dir=""
  local source_metallib=""
  local candidate_configuration=""

  for candidate_configuration in "${AVC_CONFIGURATION}" Debug Release; do
    for candidate in "${HOME}"/Library/Developer/Xcode/DerivedData/AVCMeter-*/Build/Intermediates.noindex/AVCMeter.build/${candidate_configuration}/AVCMeterKit.build/Metal; do
      if [[ -d "${candidate}" && -f "${candidate}/MetalWaveform.air" ]]; then
        source_metal_dir="${candidate}"
        break 2
      fi
    done
  done

  for candidate_configuration in "${AVC_CONFIGURATION}" Debug Release; do
    for candidate in "${HOME}"/Library/Developer/Xcode/DerivedData/AVCMeter-*/Build/Products/${candidate_configuration}/AVCMeterKit.framework/Versions/A/Resources/default.metallib; do
      if [[ -f "${candidate}" ]]; then
        source_metallib="${candidate}"
        break 2
      fi
    done
  done

  if [[ -n "${source_metal_dir}" ]]; then
    local dest_metal_dir="${AVC_DERIVED_DATA_DIR}/Build/Intermediates.noindex/AVCMeter.build/${AVC_CONFIGURATION}/AVCMeterKit.build/Metal"
    if [[ ! -f "${dest_metal_dir}/MetalWaveform.air" ]]; then
      echo "Seeding AVCMeterKit compiled Metal intermediates from ${source_metal_dir}"
      mkdir -p "$(dirname "${dest_metal_dir}")"
      /usr/bin/ditto "${source_metal_dir}" "${dest_metal_dir}"
    fi
  fi

  if [[ -n "${source_metallib}" ]]; then
    local dest_metallib="${AVC_BUILD_DIR}/AVCMeterKit.framework/Versions/A/Resources/default.metallib"
    if [[ ! -f "${dest_metallib}" ]]; then
      echo "Seeding AVCMeterKit default.metallib from ${source_metallib}"
      mkdir -p "$(dirname "${dest_metallib}")"
      /usr/bin/ditto "${source_metallib}" "${dest_metallib}"
    fi
  fi
}

seed_swift_header() {
  local source_header=""
  local candidate_configuration=""

  for candidate_configuration in "${AVC_CONFIGURATION}" Debug Release; do
    for candidate in \
      "${AVC_DERIVED_DATA_DIR}/Build/Intermediates.noindex/AVCMeter.build/${candidate_configuration}/AVCMeterKit.build/Objects-normal/arm64/AVCMeterKit-Swift.h" \
      "${AVC_DERIVED_DATA_DIR}/Build/Intermediates.noindex/AVCMeter.build/${candidate_configuration}/AVCMeterKit.build/Objects-normal/x86_64/AVCMeterKit-Swift.h" \
      "${AVC_ROOT}/build/AVCMeter.build/${candidate_configuration}/AVCMeterKit.build/Objects-normal/arm64/AVCMeterKit-Swift.h"; do
      if [[ -f "${candidate}" ]]; then
        source_header="${candidate}"
        break 2
      fi
    done
  done

  if [[ -z "${source_header}" ]]; then
    return 0
  fi

  local dest_header="${AVC_BUILD_DIR}/AVCMeterKit.framework/Headers/AVCMeterKit-Swift.h"
  mkdir -p "$(dirname "${dest_header}")"

  if [[ -f "${dest_header}" ]] && /usr/bin/cmp -s "${source_header}" "${dest_header}"; then
    return 0
  fi

  echo "Seeding AVCMeterKit Swift header from ${source_header}"
  /usr/bin/ditto "${source_header}" "${dest_header}"
}

echo "Building AVCMeterKit.framework (${AVC_CONFIGURATION})"

if [[ "${1:-}" != "--verify" ]]; then
  trash_and_remove_path "${AVC_BUILD_DIR}"
  trash_and_remove_path "${AVC_DERIVED_DATA_DIR}/Build"
  trash_and_remove_path "${AVC_DERIVED_DATA_DIR}/Index.noindex"
  trash_and_remove_path "${AVC_DERIVED_DATA_DIR}/ModuleCache.noindex"
  trash_and_remove_path "${AVC_DERIVED_DATA_DIR}/SDKStatCaches.noindex"
fi

mkdir -p "${AVC_BUILD_DIR}" "${AVC_INTERMEDIATES_DIR}" "${AVC_PRODUCTS_DIR}"
seed_source_packages
seed_metal_artifacts

if [[ "${1:-}" == "--verify" ]]; then
  if [[ -d "${AVC_BUILD_DIR}/AVCMeterKit.framework" ]]; then
    normalize_install_name
    echo "Using prebuilt AVCMeterKit.framework at ${AVC_BUILD_DIR}"
    exit 0
  fi

  echo "AVCMeterKit.framework is missing at ${AVC_BUILD_DIR}"
  echo "Run: bash \"${HOST_ROOT}/Scripts/build_avcmeterkit.sh\""
  exit 1
fi

env -i \
  HOME="${HOME}" \
  LOGNAME="${LOGNAME:-$(id -un)}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin" \
  TMPDIR="${TMPDIR:-/tmp}" \
  USER="${USER:-$(id -un)}" \
  DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" \
  xcodebuild \
    -project "${AVC_ROOT}/AVCMeter.xcodeproj" \
    -scheme AVCMeterKit \
    -configuration "${AVC_CONFIGURATION}" \
    -derivedDataPath "${AVC_DERIVED_DATA_DIR}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    -disableAutomaticPackageResolution \
    SYMROOT="${AVC_PRODUCTS_DIR}" \
    OBJROOT="${AVC_INTERMEDIATES_DIR}" \
    CONFIGURATION_BUILD_DIR="${AVC_BUILD_DIR}" \
    build

normalize_install_name
rewrite_module_map
seed_swift_header
