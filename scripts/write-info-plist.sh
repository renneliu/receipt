#!/bin/bash
set -euo pipefail

# 用法: write-info-plist.sh <Info.plist 输出路径>
if [ $# -lt 1 ]; then
    echo "Usage: $0 <path/to/Info.plist>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=version-lib.sh
source "${SCRIPT_DIR}/version-lib.sh"
read_version

OUT="$1"
mkdir -p "$(dirname "$OUT")"

cat > "$OUT" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleExecutable</key>
    <string>ReceiptPrinter</string>
    <key>CFBundleIdentifier</key>
    <string>com.receiptprinter.app</string>
    <key>CFBundleName</key>
    <string>ReceiptPrinter</string>
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
                <string>com.receiptprinter</string>
            </array>
            <key>CFBundleURLName</key>
            <string>OAuth Redirect</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "Info.plist → ${MARKETING_VERSION} (${BUILD_NUMBER})"
