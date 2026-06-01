#!/bin/bash
# Build phase script to check and validate local dependency artifacts.

set -euo pipefail

echo "note: [Local Frameworks] Checking local dependency artifacts"

PROJECT_DIR="${PROJECT_DIR:-.}"

if [[ ! -d "${PROJECT_DIR}/.avcmeterkit-build/AVCMeterKit.framework" ]]; then
  echo "warning: [Local Frameworks] AVCMeterKit.framework is not built yet"
fi

if [[ ! -d "${PROJECT_DIR}/.firewirenetbridge-build/FireWireNetBridgeKit.framework" ]]; then
  echo "warning: [Local Frameworks] FireWireNetBridgeKit.framework is not built yet"
fi

echo "note: [Local Frameworks] Dependency artifact check complete"
