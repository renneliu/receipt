#!/bin/bash
set -euo pipefail
# Regenerate ReceiptPrinter/Resources/AppIcon.icns from AppIcon.png
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${ROOT}/ReceiptPrinter/Resources/AppIcon.png"
OUT="${ROOT}/ReceiptPrinter/Resources/AppIcon.icns"
if [ ! -f "${MASTER}" ]; then
  echo "Missing ${MASTER}" >&2
  exit 1
fi
swift "${ROOT}/scripts/generate-app-icon.swift" "${MASTER}" "${OUT}"
echo "App icon ready: ${OUT}"
