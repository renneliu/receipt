#!/bin/bash
# 备份用户配置与模板（Application Support + Preferences）
#
# 用法:
#   ./scripts/backup-userdata.sh              # 标准备份（不含 PrintDiagnostics）
#   ./scripts/backup-userdata.sh --full       # 含打印诊断目录
#   ./scripts/backup-userdata.sh --label pos  # 文件名附加标签
#   ./scripts/backup-userdata.sh --keep 20    # 只保留最近 N 份 userdata 备份
#
# 产出: backups/ReceiptPrinter-userdata-vX.Y.Z-<label>-YYYYMMDD-HHMMSS.tar.gz
# （已在 .gitignore，不会进 Git）
#
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=version-lib.sh
source scripts/version-lib.sh
read_version

FULL=0
LABEL=""
KEEP=20

while [ $# -gt 0 ]; do
    case "$1" in
        --full) FULL=1; shift ;;
        --label)
            LABEL="${2:-}"
            if [ -z "$LABEL" ]; then
                echo "--label 需要一个值" >&2
                exit 1
            fi
            shift 2
            ;;
        --keep)
            KEEP="${2:-20}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *)
            echo "未知参数: $1" >&2
            exit 1
            ;;
    esac
done

APP_SUPPORT="${HOME}/Library/Application Support/ReceiptPrinter"
PREFS_DIR="${HOME}/Library/Preferences"
STAMP="$(date +%Y%m%d-%H%M%S)"
TAG_PART="v${MARKETING_VERSION}"
if [ -n "$LABEL" ]; then
    TAG_PART="${TAG_PART}-${LABEL}"
fi
OUT_NAME="ReceiptPrinter-userdata-${TAG_PART}-${STAMP}.tar.gz"
OUT_DIR="$(pwd)/backups"
OUT_PATH="${OUT_DIR}/${OUT_NAME}"

mkdir -p "$OUT_DIR"

if [ ! -d "$APP_SUPPORT" ]; then
    echo "未找到用户数据目录: $APP_SUPPORT" >&2
    exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rp-userdata-backup.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$STAGE/ReceiptPrinter" "$STAGE/Preferences"

echo "━━━ 备份 Application Support ━━━"
RSYNC_ARGS=(-a --exclude '.DS_Store')
if [ "$FULL" -eq 0 ]; then
    RSYNC_ARGS+=(--exclude 'PrintDiagnostics')
fi
rsync "${RSYNC_ARGS[@]}" "$APP_SUPPORT/" "$STAGE/ReceiptPrinter/"

echo "━━━ 备份 Preferences（设置 / 模板选择等） ━━━"
for plist in \
    "com.receiptprinter.app.plist" \
    "ReceiptPrinter.plist"
do
    src="${PREFS_DIR}/${plist}"
    if [ -f "$src" ]; then
        cp -p "$src" "$STAGE/Preferences/${plist}"
        echo "  + $plist"
    else
        echo "  · 跳过（不存在）: $plist"
    fi
done

if command -v plutil >/dev/null 2>&1; then
    for plist in "$STAGE"/Preferences/*.plist; do
        [ -f "$plist" ] || continue
        base="$(basename "$plist" .plist)"
        plutil -convert xml1 -o "$STAGE/Preferences/${base}.xml" "$plist" 2>/dev/null || true
    done
fi

{
    echo "ReceiptPrinter userdata backup"
    echo "created: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "app_version: ${MARKETING_VERSION}"
    echo "build: ${BUILD_NUMBER}"
    echo "host: $(scutil --get ComputerName 2>/dev/null || hostname)"
    if [ "$FULL" -eq 1 ]; then
        echo "include_print_diagnostics: yes"
    else
        echo "include_print_diagnostics: no"
    fi
    echo "app_support: ${APP_SUPPORT}"
    echo "contents:"
    (cd "$STAGE" && find . -type f | sed 's|^\./||' | sort)
} > "$STAGE/MANIFEST.txt"

echo "━━━ 打包 ━━━"
tar -czf "$OUT_PATH" -C "$STAGE" .
BYTES="$(wc -c < "$OUT_PATH" | tr -d ' ')"
echo "已写入: $OUT_PATH (${BYTES} bytes)"

# 保留最近 N 份 userdata 备份（macOS Bash 3.2 兼容）
if [ "$KEEP" -gt 0 ] 2>/dev/null; then
    idx=0
    # shellcheck disable=SC2012
    for f in $(ls -1t "$OUT_DIR"/ReceiptPrinter-userdata-*.tar.gz 2>/dev/null); do
        idx=$((idx + 1))
        if [ "$idx" -gt "$KEEP" ]; then
            if [ "$idx" -eq $((KEEP + 1)) ]; then
                echo "清理旧备份（保留最近 ${KEEP} 份）:"
            fi
            echo "  - $(basename "$f")"
            rm -f "$f"
        fi
    done
fi

echo ""
echo "恢复: ./scripts/restore-userdata.sh \"$OUT_PATH\""
