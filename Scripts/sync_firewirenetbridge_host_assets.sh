#!/bin/bash
set -euo pipefail

# This script is called by Xcode build system with required environment variables:
# PROJECT_DIR, TARGET_BUILD_DIR, WRAPPER_NAME
if [[ -z "${PROJECT_DIR:-}" ]]; then
  echo "error: PROJECT_DIR environment variable not set" >&2
  exit 1
fi

if [[ -z "${TARGET_BUILD_DIR:-}" ]]; then
  echo "error: TARGET_BUILD_DIR environment variable not set" >&2
  exit 1
fi

if [[ -z "${WRAPPER_NAME:-}" ]]; then
  echo "error: WRAPPER_NAME environment variable not set" >&2
  exit 1
fi

PROJECT_ROOT="${PROJECT_DIR}"
BUILD_ROOT="${TARGET_BUILD_DIR}"
APP_WRAPPER_NAME="${WRAPPER_NAME}"

SOURCE_ROOT="${FIREWIRE_NET_BRIDGE_BUILD_DIR:-${PROJECT_ROOT}/.firewirenetbridge-build}"
SOURCE_SENDER="${SOURCE_ROOT}/FireWireNetBridgeSender"

APP_BUNDLE="${BUILD_ROOT}/${APP_WRAPPER_NAME}"
APP_RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

DEST_PRODUCTS_SENDER="${BUILD_ROOT}/FireWireNetBridgeSender"
DEST_APP_SENDER="${APP_RESOURCES_DIR}/FireWireNetBridgeSender"

copy_sender_binary() {
  local source_path="$1"
  local destination_path="$2"

  /bin/rm -f "${destination_path}"
  /bin/cat "${source_path}" > "${destination_path}"
}

if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "FireWire host sync skipped: app bundle missing at ${APP_BUNDLE}" >&2
  exit 0
fi

if [[ ! -d "${APP_RESOURCES_DIR}" ]]; then
  echo "warning: FireWire host sync skipped: resources directory missing at ${APP_RESOURCES_DIR}" >&2
  exit 0
fi

if [[ -f "${SOURCE_SENDER}" ]]; then
  copy_sender_binary "${SOURCE_SENDER}" "${DEST_PRODUCTS_SENDER}"
  copy_sender_binary "${SOURCE_SENDER}" "${DEST_APP_SENDER}"
  /bin/chmod +x "${DEST_PRODUCTS_SENDER}" "${DEST_APP_SENDER}"
else
  echo "warning: FireWire host sync could not find sender payload at ${SOURCE_SENDER}" >&2
fi
