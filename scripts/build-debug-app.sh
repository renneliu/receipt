#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ReceiptPrinter"
BUILD_DIR=".build/debug"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building debug ${APP_NAME}..."
swift build

mkdir -p "${MACOS}" "${RESOURCES}"
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"

"$(dirname "$0")/write-info-plist.sh" "${CONTENTS}/Info.plist"

if [ -d "ReceiptPrinter/Resources" ]; then
    cp -R ReceiptPrinter/Resources/* "${RESOURCES}/" 2>/dev/null || true
fi

# macOS rejects unsigned / stale ad-hoc Mach-O copied into a bundle (SIGKILL codesign).
codesign --force --deep --sign - \
    --entitlements "ReceiptPrinter/ReceiptPrinter.entitlements" \
    "${APP_DIR}"

echo "Built ${APP_DIR}"
echo "Run with: open dist/ReceiptPrinter.app"
