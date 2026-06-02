#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="${APP_NAME:-PodcastPreview}"
PROJECT_PATH="${PROJECT_PATH:-${REPO_ROOT}/PodcastPreview.xcodeproj}"
SCHEME="${SCHEME:-PodcastPreview}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-8CZML8FK2D}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-${REPO_ROOT}/Packaging/ExportOptions-DeveloperID.plist}"
BUILD_ROOT="${BUILD_ROOT:-${REPO_ROOT}/build/ReleaseDMG}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${BUILD_ROOT}/${APP_NAME}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${BUILD_ROOT}/Export}"
STAGE_PATH="${STAGE_PATH:-${BUILD_ROOT}/DMGStage}"
DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_IDENTITY:-A5D4019DBFEDE7727487D49BD08257C46A72E7E0}"
MAIN_BUNDLE_ID="${MAIN_BUNDLE_ID:-com.chrisizatt.PodcastPreview}"
MAC_WIDGET_BUNDLE_ID="${MAC_WIDGET_BUNDLE_ID:-com.chrisizatt.PodcastPreview.PodcastPreviewMacWidgetsExtension}"
MAIN_PROFILE_NAME="${MAIN_PROFILE_NAME:-PodcastPreview Developer ID Application 2026}"
MAC_WIDGET_PROFILE_NAME="${MAC_WIDGET_PROFILE_NAME:-PodcastPreview Mac W Developer ID Application 2026}"
PROFILE_INSTALL_DIR="${PROFILE_INSTALL_DIR:-${HOME}/Library/MobileDevice/Provisioning Profiles}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
EXTERNAL_ARTIFACTS_DIR="${EXTERNAL_ARTIFACTS_DIR:-${REPO_ROOT}/Artifacts/External}"
EXTERNAL_ARTIFACT_LOCALISER="${EXTERNAL_ARTIFACT_LOCALISER:-${SCRIPT_DIR}/localise_external_artifacts.sh}"
EXTERNAL_ARTIFACT_BUILDER="${EXTERNAL_ARTIFACT_BUILDER:-${SCRIPT_DIR}/stage_external_artifacts.sh}"
SKIP_ARCHIVE=0
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
INCLUDE_EXTERNAL_ARTIFACTS="${INCLUDE_EXTERNAL_ARTIFACTS:-0}"
BUILD_EXTERNAL_ARTIFACTS="${BUILD_EXTERNAL_ARTIFACTS:-0}"
ALLOW_DIRECT_RESIGN_FALLBACK="${ALLOW_DIRECT_RESIGN_FALLBACK:-0}"
CLEAN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Builds a Developer ID export and packages it as a DMG.

Options:
  --clean          Remove the release packaging build directory first.
  --skip-archive   Reuse the existing exported app in ${EXPORT_PATH}.
  --skip-notarize  Create the DMG but do not submit or staple it.
  --include-external-artifacts
                  Bundle signed payloads from ${EXTERNAL_ARTIFACTS_DIR}.
  --build-external-artifacts
                  Build, stage, sign, and bundle local sibling payloads.
                  Implies --include-external-artifacts.
  --allow-direct-resign-fallback
                  If xcodebuild export fails, copy the archived app and re-sign it directly.
  -h, --help       Show this help.

Environment:
  NOTARY_PROFILE   notarytool keychain profile to use for DMG notarization.
  DEVELOPER_ID_IDENTITY
                   codesigning identity for fallback re-signing.
  MAIN_PROFILE_NAME
                   Developer ID provisioning profile name for ${MAIN_BUNDLE_ID}.
  MAC_WIDGET_PROFILE_NAME
                   Developer ID provisioning profile name for ${MAC_WIDGET_BUNDLE_ID}.
  EXTERNAL_ARTIFACTS_DIR
                   optional payload directory, default: ${EXTERNAL_ARTIFACTS_DIR}
  EXTERNAL_ARTIFACT_LOCALISER
                   script used to copy and sign external payloads.
  EXTERNAL_ARTIFACT_BUILDER
                   script used to build and stage external payloads.
  BUILD_ROOT       output directory, default: ${BUILD_ROOT}
  TEAM_ID          Apple Developer Team ID, default: ${TEAM_ID}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN=1
      ;;
    --skip-archive)
      SKIP_ARCHIVE=1
      ;;
    --skip-notarize)
      SKIP_NOTARIZE=1
      ;;
    --include-external-artifacts)
      INCLUDE_EXTERNAL_ARTIFACTS=1
      ;;
    --build-external-artifacts)
      BUILD_EXTERNAL_ARTIFACTS=1
      INCLUDE_EXTERNAL_ARTIFACTS=1
      ;;
    --allow-direct-resign-fallback)
      ALLOW_DIRECT_RESIGN_FALLBACK=1
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

plist_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :${key}" "${REPO_ROOT}/PodcastPreview/Info.plist"
}

find_exported_app() {
  if [[ -d "${EXPORT_PATH}/${APP_NAME}.app" ]]; then
    echo "${EXPORT_PATH}/${APP_NAME}.app"
    return 0
  fi

  /usr/bin/find "${EXPORT_PATH}" -maxdepth 4 -type d -name "${APP_NAME}.app" -print -quit
}

resolve_developer_id_identity() {
  if [[ "${DEVELOPER_ID_IDENTITY}" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    echo "${DEVELOPER_ID_IDENTITY}"
    return 0
  fi

  local identities
  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep "Developer ID Application: .*(${TEAM_ID})" || true)"
  local identity_count
  identity_count="$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' <<< "${identities}")"

  if [[ "${identity_count}" -eq 0 ]]; then
    echo "Could not find a Developer ID Application identity for team ${TEAM_ID}." >&2
    echo "Install/create one in Xcode Settings > Accounts > Manage Certificates." >&2
    exit 1
  fi

  if [[ "${identity_count}" -gt 1 ]]; then
    echo "Multiple Developer ID Application identities found for team ${TEAM_ID}; using the first valid identity." >&2
  fi

  /usr/bin/awk 'NF { print $2; exit }' <<< "${identities}"
}

DEVELOPER_ID_RESOLVED_IDENTITY="$(resolve_developer_id_identity)"

codesign_item() {
  local item="$1"
  /usr/bin/codesign --force --timestamp --options runtime \
    --sign "${DEVELOPER_ID_RESOLVED_IDENTITY}" \
    "${item}"
}

codesign_item_with_empty_entitlements() {
  local item="$1"
  local empty_entitlements="${BUILD_ROOT}/empty-entitlements.plist"

  if [[ ! -f "${empty_entitlements}" ]]; then
    /bin/cat > "${empty_entitlements}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST
  fi

  /usr/bin/codesign --force --timestamp --options runtime \
    --entitlements "${empty_entitlements}" \
    --sign "${DEVELOPER_ID_RESOLVED_IDENTITY}" \
    "${item}"
}

codesign_app_preserving_entitlements() {
  local app_path="$1"
  /usr/bin/codesign --force --timestamp --options runtime \
    --preserve-metadata=entitlements \
    --sign "${DEVELOPER_ID_RESOLVED_IDENTITY}" \
    "${app_path}"
}

sanitize_smappservice_helper_entitlements() {
  local app_path="$1"
  local helper
  local helper_names=(
    "PodcastPreviewHardwareAgent"
    "com.chrisizatt.PodcastPreview.PowerMetricsService"
  )

  echo "Removing provisioning-profile entitlements from SMAppService daemon tools"
  for helper in "${helper_names[@]}"; do
    local helper_path="${app_path}/Contents/Library/LaunchServices/${helper}"
    if [[ -f "${helper_path}" && -x "${helper_path}" ]]; then
      codesign_item_with_empty_entitlements "${helper_path}"
    fi
  done

  echo "Refreshing main app signature after helper re-signing"
  codesign_app_preserving_entitlements "${app_path}"
}

install_profile_by_name() {
  local bundle_id="$1"
  local profile_name="$2"
  local dir
  local profile
  local tmp
  local name
  local app_identifier
  local uuid

  /bin/mkdir -p "${PROFILE_INSTALL_DIR}"

  for dir in \
    "${PROFILE_INSTALL_DIR}" \
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "${HOME}/Downloads"; do
    [[ -d "${dir}" ]] || continue

    while IFS= read -r profile; do
      tmp="$(/usr/bin/mktemp -t podcastpreview-profile)"
      if ! /usr/bin/security cms -D -i "${profile}" > "${tmp}" 2>/dev/null; then
        /bin/rm -f "${tmp}"
        continue
      fi

      name="$(/usr/libexec/PlistBuddy -c "Print :Name" "${tmp}" 2>/dev/null || true)"
      app_identifier="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "${tmp}" 2>/dev/null || true)"
      uuid="$(/usr/libexec/PlistBuddy -c "Print :UUID" "${tmp}" 2>/dev/null || true)"
      /bin/rm -f "${tmp}"

      if [[ "${name}" == "${profile_name}" && "${app_identifier}" == "${TEAM_ID}.${bundle_id}" && -n "${uuid}" ]]; then
        local destination="${PROFILE_INSTALL_DIR}/${uuid}.provisionprofile"
        if [[ "${profile}" != "${destination}" ]]; then
          /bin/cp "${profile}" "${destination}"
        fi
        echo "Installed provisioning profile: ${profile_name}"
        return 0
      fi
    done < <(/usr/bin/find "${dir}" -maxdepth 1 \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) -print 2>/dev/null)
  done

  echo "Could not find required Developer ID provisioning profile: ${profile_name}" >&2
  echo "Expected bundle identifier: ${bundle_id}" >&2
  echo "Download it from Apple Developer or set MAIN_PROFILE_NAME/MAC_WIDGET_PROFILE_NAME." >&2
  exit 1
}

install_export_profiles() {
  install_profile_by_name "${MAIN_BUNDLE_ID}" "${MAIN_PROFILE_NAME}"
  install_profile_by_name "${MAC_WIDGET_BUNDLE_ID}" "${MAC_WIDGET_PROFILE_NAME}"
}

prepare_export_options_plist() {
  local resolved_plist="${BUILD_ROOT}/ExportOptions-DeveloperID.generated.plist"

  /bin/cp "${EXPORT_OPTIONS_PLIST}" "${resolved_plist}"
  /usr/libexec/PlistBuddy -c "Set :teamID ${TEAM_ID}" "${resolved_plist}"
  /usr/libexec/PlistBuddy -c "Set :signingCertificate ${DEVELOPER_ID_RESOLVED_IDENTITY}" "${resolved_plist}"
  /usr/libexec/PlistBuddy -c "Set :provisioningProfiles:${MAIN_BUNDLE_ID} ${MAIN_PROFILE_NAME}" "${resolved_plist}"
  /usr/libexec/PlistBuddy -c "Set :provisioningProfiles:${MAC_WIDGET_BUNDLE_ID} ${MAC_WIDGET_PROFILE_NAME}" "${resolved_plist}"

  echo "${resolved_plist}"
}

append_external_artifact_archive_settings() {
  local frameworks_dir="${EXTERNAL_ARTIFACTS_DIR}/Frameworks"
  local swift_flags=()

  if [[ ! -d "${EXTERNAL_ARTIFACTS_DIR}" ]]; then
    echo "External artifacts were requested, but ${EXTERNAL_ARTIFACTS_DIR} does not exist." >&2
    exit 1
  fi

  if [[ -d "${frameworks_dir}" ]]; then
    ARCHIVE_BUILD_SETTINGS+=("FRAMEWORK_SEARCH_PATHS=\$(inherited) ${frameworks_dir}")

    if [[ -d "${frameworks_dir}/AVCMeterKit.framework" ]]; then
      swift_flags+=("-DINCLUDE_AVCMETERKIT")
    fi

    if [[ -d "${frameworks_dir}/AudioVisualiserConverterKit.framework" ]]; then
      swift_flags+=("-DINCLUDE_AUDIO_VISUALISER")
    fi
  fi

  if [[ "${#swift_flags[@]}" -gt 0 ]]; then
    ARCHIVE_BUILD_SETTINGS+=("OTHER_SWIFT_FLAGS=\$(inherited) ${swift_flags[*]}")
  fi
}

build_external_artifacts() {
  if [[ "${BUILD_EXTERNAL_ARTIFACTS}" != "1" ]]; then
    return 0
  fi

  if [[ ! -x "${EXTERNAL_ARTIFACT_BUILDER}" ]]; then
    echo "External artifact builder is missing or not executable: ${EXTERNAL_ARTIFACT_BUILDER}" >&2
    exit 1
  fi

  echo "Building and staging external artifacts"
  CONFIGURATION="${CONFIGURATION}" \
    TEAM_ID="${TEAM_ID}" \
    DEVELOPER_ID_IDENTITY="${DEVELOPER_ID_RESOLVED_IDENTITY}" \
    EXTERNAL_ARTIFACTS_DIR="${EXTERNAL_ARTIFACTS_DIR}" \
    "${EXTERNAL_ARTIFACT_BUILDER}" --clean
}

embed_external_artifacts() {
  local app_path="$1"

  if [[ "${INCLUDE_EXTERNAL_ARTIFACTS}" != "1" ]]; then
    return 0
  fi

  if [[ ! -x "${EXTERNAL_ARTIFACT_LOCALISER}" ]]; then
    echo "External artifact localiser is missing or not executable: ${EXTERNAL_ARTIFACT_LOCALISER}" >&2
    exit 1
  fi

  "${EXTERNAL_ARTIFACT_LOCALISER}" \
    --app-path "${app_path}" \
    --artifacts-dir "${EXTERNAL_ARTIFACTS_DIR}" \
    --signing-identity "${DEVELOPER_ID_RESOLVED_IDENTITY}" \
    --work-dir "${BUILD_ROOT}/ExternalArtifactSigning"

  echo "Refreshing main app signature after external artifact localisation"
  codesign_app_preserving_entitlements "${app_path}"
}

resign_exported_app() {
  local app_path="$1"
  local helper

  echo "Removing embedded provisioning profiles"
  /usr/bin/find "${app_path}" -name embedded.provisionprofile -delete

  echo "Signing nested frameworks"
  while IFS= read -r helper; do
    codesign_item "${helper}"
  done < <(/usr/bin/find "${app_path}/Contents/Frameworks" -maxdepth 2 -type d -name "*.framework" -print 2>/dev/null | sort)

  echo "Signing nested app extensions and driver bundles"
  while IFS= read -r helper; do
    codesign_item "${helper}"
  done < <(/usr/bin/find "${app_path}" -type d \( -name "*.appex" -o -name "*.driver" -o -name "*.plugin" \) -print | sort)

  echo "Signing bundled helper tools"
  while IFS= read -r helper; do
    if [[ -f "${helper}" && -x "${helper}" ]]; then
      codesign_item "${helper}"
    fi
  done < <(/usr/bin/find "${app_path}/Contents/Library/LaunchServices" -maxdepth 1 -type f -print 2>/dev/null | sort)

  echo "Signing main app"
  codesign_item "${app_path}"
}

direct_export_from_archive() {
  local archived_app="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
  if [[ ! -d "${archived_app}" ]]; then
    echo "Could not find archived app: ${archived_app}" >&2
    exit 1
  fi

  /bin/rm -rf "${EXPORT_PATH}"
  /bin/mkdir -p "${EXPORT_PATH}"
  /usr/bin/ditto "${archived_app}" "${EXPORT_PATH}/${APP_NAME}.app"
  resign_exported_app "${EXPORT_PATH}/${APP_NAME}.app"
}

if [[ "${CLEAN}" == "1" ]]; then
  /bin/rm -rf "${BUILD_ROOT}"
fi

/bin/mkdir -p "${BUILD_ROOT}"
build_external_artifacts

if [[ "${SKIP_ARCHIVE}" != "1" ]]; then
  /bin/rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}"

  ARCHIVE_BUILD_SETTINGS=(
    "DEVELOPMENT_TEAM=${TEAM_ID}"
    "CODE_SIGN_STYLE=Automatic"
    "ARCHS=arm64 x86_64"
    "ONLY_ACTIVE_ARCH=NO"
  )

  if [[ "${INCLUDE_EXTERNAL_ARTIFACTS}" == "1" ]]; then
    append_external_artifact_archive_settings
  fi

  echo "Archiving ${APP_NAME} (${CONFIGURATION})"
  /usr/bin/xcodebuild archive \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination "generic/platform=macOS" \
    -archivePath "${ARCHIVE_PATH}" \
    "${ARCHIVE_BUILD_SETTINGS[@]}"

  echo "Exporting Developer ID app"
  install_export_profiles
  RESOLVED_EXPORT_OPTIONS_PLIST="$(prepare_export_options_plist)"
  if ! /usr/bin/xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_PATH}" \
    -exportOptionsPlist "${RESOLVED_EXPORT_OPTIONS_PLIST}"; then
    if [[ "${ALLOW_DIRECT_RESIGN_FALLBACK}" == "1" ]]; then
      echo "xcodebuild export failed; falling back to direct Developer ID re-signing."
      direct_export_from_archive
    else
      echo "xcodebuild export failed; not falling back because direct re-signing can break entitlements." >&2
      echo "Use --allow-direct-resign-fallback only for local signing experiments." >&2
      exit 1
    fi
  fi
fi

APP_PATH="$(find_exported_app)"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "Could not find exported ${APP_NAME}.app in ${EXPORT_PATH}" >&2
  exit 1
fi

embed_external_artifacts "${APP_PATH}"
sanitize_smappservice_helper_entitlements "${APP_PATH}"

VERSION="$(plist_value CFBundleShortVersionString)"
BUILD="$(plist_value CFBundleVersion)"
DMG_BASENAME="${APP_NAME}-${VERSION}-${BUILD}"
DMG_PATH="${BUILD_ROOT}/${DMG_BASENAME}.dmg"
VOLUME_NAME="${APP_NAME} ${VERSION}"

echo "Verifying exported app signature"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
if ! /usr/sbin/spctl --assess --type execute --verbose=4 "${APP_PATH}"; then
  echo "Gatekeeper assessment failed before notarization; continuing to DMG creation."
fi

echo "Staging DMG contents"
/bin/rm -rf "${STAGE_PATH}" "${DMG_PATH}"
/bin/mkdir -p "${STAGE_PATH}"
/usr/bin/ditto "${APP_PATH}" "${STAGE_PATH}/${APP_NAME}.app"
/bin/ln -s /Applications "${STAGE_PATH}/Applications"

echo "Creating DMG: ${DMG_PATH}"
/usr/bin/hdiutil create \
  -volname "${VOLUME_NAME}" \
  -srcfolder "${STAGE_PATH}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "${DMG_PATH}"

echo "Signing DMG"
/usr/bin/codesign --force --timestamp \
  --sign "${DEVELOPER_ID_RESOLVED_IDENTITY}" \
  "${DMG_PATH}"
/usr/bin/codesign --verify --verbose=2 "${DMG_PATH}"

if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  echo "Skipping notarization by request."
elif [[ -n "${NOTARY_PROFILE}" ]]; then
  echo "Submitting DMG for notarization with profile: ${NOTARY_PROFILE}"
  /usr/bin/xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --team-id "${TEAM_ID}" \
    --wait

  echo "Stapling notarization ticket"
  /usr/bin/xcrun stapler staple "${DMG_PATH}"

  echo "Assessing stapled DMG"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "${DMG_PATH}"
else
  echo "NOTARY_PROFILE is not set, so the DMG was not notarized." >&2
  echo "Set NOTARY_PROFILE and rerun, or pass --skip-notarize for internal-only packaging." >&2
  exit 1
fi

echo "DMG ready: ${DMG_PATH}"
