#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="SnapOCR"
BUILD_DIR=".build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"

echo ">> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "build failed: ${BIN_PATH} missing" >&2
  exit 1
fi

echo ">> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}"          "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"

codesign --force --sign - --deep "${APP_DIR}" || true

echo ""
echo "Built: ${APP_DIR}"
