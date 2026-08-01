#!/bin/bash
# App Store / 发布版构建（与本地日常包隔离）
#
# - 编译定义 APPSTORE：只种子「示例影票」、不装 IMAX/Orpheum/Dendy、不种子旧模板库
# - TMDB Key 由用户在设置中自填；无 Gmail
# - Bundle ID / 数据目录与本地包不同，不会读写 ~/Library/Application Support/ReceiptPrinter
#
# 产出: dist/ReceiptPrinterStore.app
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ReceiptPrinterStore"
BUILD_DIR=".build/release"
BIN_NAME="ReceiptPrinter"
APP_DIR="dist/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
ENTITLEMENTS="ReceiptPrinter/ReceiptPrinterAppStore.entitlements"

echo "━━━ App Store 发布构建 ━━━"
echo "清理旧产物…"
rm -rf "${APP_DIR}"
# 避免与本地 release 二进制互相覆盖混淆：仍用同一 target 名，但用 -DAPPSTORE
swift build -c release -Xswiftc -DAPPSTORE

mkdir -p "${MACOS}" "${RESOURCES}"
cp "${BUILD_DIR}/${BIN_NAME}" "${MACOS}/${BIN_NAME}"

BUNDLE_ID="com.receiptprinter.store" \
APP_NAME="ReceiptPrinter" \
URL_SCHEME="com.receiptprinter.store" \
    "$(dirname "$0")/write-info-plist.sh" "${CONTENTS}/Info.plist"

if [ -d "ReceiptPrinter/Resources" ]; then
    # 复制资源，但不要把本机测试用的敏感文件打进去（Secrets 不在 Resources）
    rsync -a --exclude '.DS_Store' ReceiptPrinter/Resources/ "${RESOURCES}/"
fi

codesign --force --deep --sign - \
    --entitlements "${ENTITLEMENTS}" \
    "${APP_DIR}"

echo ""
echo "Built ${APP_DIR}"
echo "  Bundle ID: com.receiptprinter.store"
echo "  Data dir:  ~/Library/Application Support/ReceiptPrinterStore"
echo "  Local dir: ~/Library/Application Support/ReceiptPrinter  (untouched)"
echo ""
echo "Run store build: open ${APP_DIR}"
echo "Run local build:  ./scripts/build-debug-app.sh && open dist/ReceiptPrinter.app"
echo ""
echo "上传 App Store Connect 请用 Xcode Archive："
echo "  open ReceiptPrinterStore.xcodeproj"
echo "  Product → Archive → Distribute App → App Store Connect"
echo "（本脚本为 ad-hoc 签名，不能直接上传。）"
