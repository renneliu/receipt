#!/bin/bash
set -euo pipefail
# Regenerate ReceiptPrinter/Resources/AppIcon.icns from AppIcon.png
# Uses sips + iconutil (more reliable than AppKit PNG for iconutil).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${ROOT}/ReceiptPrinter/Resources/AppIcon.png"
OUT="${ROOT}/ReceiptPrinter/Resources/AppIcon.icns"
ICONSET="${ROOT}/ReceiptPrinter/Resources/AppIcon.iconset"

if [ ! -f "${MASTER}" ]; then
  echo "Missing ${MASTER}" >&2
  exit 1
fi

rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

make_size() {
  local px="$1" name="$2"
  sips -z "${px}" "${px}" "${MASTER}" --out "${ICONSET}/${name}" >/dev/null
  sips -s format png "${ICONSET}/${name}" --out "${ICONSET}/${name}" >/dev/null
  xattr -cr "${ICONSET}/${name}" 2>/dev/null || true
}

make_size 16   icon_16x16.png
make_size 32   icon_16x16@2x.png
make_size 32   icon_32x32.png
make_size 64   icon_32x32@2x.png
make_size 128  icon_128x128.png
make_size 256  icon_128x128@2x.png
make_size 256  icon_256x256.png
make_size 512  icon_256x256@2x.png
make_size 512  icon_512x512.png
make_size 1024 icon_512x512@2x.png

iconutil -c icns -o "${OUT}" "${ICONSET}"
rm -rf "${ICONSET}"
echo "App icon ready: ${OUT}"
