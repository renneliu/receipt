#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ReceiptPrinter"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building ${APP_NAME}..."
swift build -c release

mkdir -p "${MACOS}" "${RESOURCES}"
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"

"$(dirname "$0")/write-info-plist.sh" "${CONTENTS}/Info.plist"

if [ -d "ReceiptPrinter/Resources" ]; then
    cp -R ReceiptPrinter/Resources/* "${RESOURCES}/" 2>/dev/null || true
fi

echo "Built ${APP_DIR}"
