#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ROOT="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
AVK_ROOT="${AUDIO_VISUALISER_ROOT:-${HOST_ROOT}/../Audio Visualiser Conveter}"
if [[ -d "${AVK_ROOT}" ]]; then
  AVK_ROOT="$(cd "${AVK_ROOT}" && pwd)"
fi
AVK_BUILD_DIR="${HOST_ROOT}/.audiovisualiserkit-build"
AVK_DERIVED_DATA_DIR="${HOST_ROOT}/.derivedData-audiovisualiserkit"
AVK_INTERMEDIATES_DIR="${AVK_DERIVED_DATA_DIR}/Build/Intermediates.noindex"
AVK_PRODUCTS_DIR="${AVK_DERIVED_DATA_DIR}/Build/Products"
AVK_CONFIGURATION="${CONFIGURATION:-Debug}"
AVK_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.5}"
AVK_SWIFT_COMPILATION_MODE="${SWIFT_COMPILATION_MODE:-singlefile}"
AVK_SWIFT_OPTIMIZATION_LEVEL="${SWIFT_OPTIMIZATION_LEVEL:--Onone}"
AVK_INSTALL_NAME="@rpath/AudioVisualiserConverterKit.framework/Versions/A/AudioVisualiserConverterKit"

# Keep the nested build independent from the host scheme's Xcode environment.
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
  local framework_binary="${AVK_BUILD_DIR}/AudioVisualiserConverterKit.framework/AudioVisualiserConverterKit"

  if [[ ! -f "${framework_binary}" ]]; then
    return 0
  fi

  local current_id
  current_id="$(/usr/bin/otool -D "${framework_binary}" | sed -n '2p' | tr -d '[:space:]')"
  if [[ "${current_id}" == "${AVK_INSTALL_NAME}" ]]; then
    return 0
  fi

  echo "Rewriting AudioVisualiserConverterKit install name: ${current_id} -> ${AVK_INSTALL_NAME}"
  /usr/bin/install_name_tool -id "${AVK_INSTALL_NAME}" "${framework_binary}"
}

echo "Building AudioVisualiserConverterKit.framework (${AVK_CONFIGURATION})"

if [[ "${1:-}" != "--verify" ]]; then
  trash_and_remove_path "${AVK_BUILD_DIR}"
  trash_and_remove_path "${AVK_DERIVED_DATA_DIR}/Build"
  trash_and_remove_path "${AVK_DERIVED_DATA_DIR}/Index.noindex"
  trash_and_remove_path "${AVK_DERIVED_DATA_DIR}/ModuleCache.noindex"
  trash_and_remove_path "${AVK_DERIVED_DATA_DIR}/SDKStatCaches.noindex"
fi

mkdir -p "${AVK_BUILD_DIR}" "${AVK_INTERMEDIATES_DIR}" "${AVK_PRODUCTS_DIR}"

if [[ "${1:-}" == "--verify" ]]; then
  if [[ -d "${AVK_BUILD_DIR}/AudioVisualiserConverterKit.framework" ]]; then
    normalize_install_name
    echo "Using prebuilt AudioVisualiserConverterKit.framework at ${AVK_BUILD_DIR}"
    exit 0
  fi

  echo "AudioVisualiserConverterKit.framework is missing at ${AVK_BUILD_DIR}"
  echo "Run: bash \"${HOST_ROOT}/Scripts/build_audiovisualiserconverterkit.sh\""
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
    -project "${AVK_ROOT}/Audio Visualiser Conveter.xcodeproj" \
    -scheme AudioVisualiserConverterKit \
    -configuration "${AVK_CONFIGURATION}" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${AVK_DERIVED_DATA_DIR}" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="${AVK_DEPLOYMENT_TARGET}" \
    SWIFT_COMPILATION_MODE="${AVK_SWIFT_COMPILATION_MODE}" \
    SWIFT_OPTIMIZATION_LEVEL="${AVK_SWIFT_OPTIMIZATION_LEVEL}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    -disableAutomaticPackageResolution \
    SYMROOT="${AVK_PRODUCTS_DIR}" \
    OBJROOT="${AVK_INTERMEDIATES_DIR}" \
    CONFIGURATION_BUILD_DIR="${AVK_BUILD_DIR}" \
    build

normalize_install_name

echo ""
echo "AudioVisualiserConverterKit build complete at: ${AVK_BUILD_DIR}"
echo "  - Framework: ${AVK_BUILD_DIR}/AudioVisualiserConverterKit.framework"
