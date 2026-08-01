#!/bin/bash
set -euo pipefail

# 用法: write-info-plist.sh <Info.plist 输出路径>
# 可选环境变量:
#   BUNDLE_ID   默认 com.receiptprinter.app
#   APP_NAME    默认 ReceiptPrinter
#   URL_SCHEME  默认 com.receiptprinter
if [ $# -lt 1 ]; then
    echo "Usage: $0 <path/to/Info.plist>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=version-lib.sh
source "${SCRIPT_DIR}/version-lib.sh"
read_version

OUT="$1"
BUNDLE_ID="${BUNDLE_ID:-com.receiptprinter.app}"
APP_NAME="${APP_NAME:-ReceiptPrinter}"
URL_SCHEME="${URL_SCHEME:-com.receiptprinter}"
mkdir -p "$(dirname "$OUT")"

cat > "$OUT" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>ReceiptPrinter</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>${URL_SCHEME}</string>
            </array>
            <key>CFBundleURLName</key>
            <string>OAuth Redirect</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Info.plist → ${MARKETING_VERSION} (${BUILD_NUMBER}) id=${BUNDLE_ID}"
