#!/bin/bash
# Generate ReceiptPrinterStore.xcodeproj for App Store Archive / Upload.
# Does not touch dist/ReceiptPrinter.app or local Application Support data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=version-lib.sh
source "${ROOT}/scripts/version-lib.sh"
read_version

export MARKETING_VERSION BUILD_NUMBER

find_xcodegen() {
    if command -v xcodegen >/dev/null 2>&1; then
        command -v xcodegen
        return 0
    fi
    for c in /opt/homebrew/bin/xcodegen /usr/local/bin/xcodegen; do
        if [ -x "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

ensure_xcodegen() {
    if XCG="$(find_xcodegen)"; then
        echo "$XCG"
        return 0
    fi
    echo "未找到 xcodegen，正在下载官方二进制…" >&2
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL -o "${tmp}/xcodegen.zip" \
        "https://github.com/yonaskolb/XcodeGen/releases/download/2.44.1/xcodegen.zip"
    unzip -q "${tmp}/xcodegen.zip" -d "${tmp}"
    echo "${tmp}/xcodegen/bin/xcodegen"
}

XCODEGEN="$(ensure_xcodegen)"

echo "Generating ReceiptPrinterStore.xcodeproj (v${MARKETING_VERSION} build ${BUILD_NUMBER})…"
"$XCODEGEN" generate --spec project.yml

echo ""
echo "Done: ReceiptPrinterStore.xcodeproj"
echo "Next in Xcode:"
echo "  1. open ReceiptPrinterStore.xcodeproj"
echo "  2. Signing & Capabilities → 选你的 Team（Automatic）"
echo "  3. Product → Archive → Distribute App → App Store Connect"
echo ""
echo "Local daily build unchanged: ./scripts/build-debug-app.sh"
echo "Local data untouched: ~/Library/Application Support/ReceiptPrinter"
