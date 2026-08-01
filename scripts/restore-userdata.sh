#!/bin/bash
# 从 backups/ 的 userdata 压缩包恢复模板与配置
#
# 用法:
#   ./scripts/restore-userdata.sh backups/ReceiptPrinter-userdata-….tar.gz
#   ./scripts/restore-userdata.sh --latest
#
# 恢复前会自动再做一份当前数据的安全备份。
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SUPPORT="${HOME}/Library/Application Support/ReceiptPrinter"
PREFS_DIR="${HOME}/Library/Preferences"
ARCHIVE=""

if [ "${1:-}" = "--latest" ]; then
    ARCHIVE="$(ls -1t backups/ReceiptPrinter-userdata-*.tar.gz 2>/dev/null | head -1 || true)"
    if [ -z "$ARCHIVE" ]; then
        echo "backups/ 下没有 userdata 备份" >&2
        exit 1
    fi
elif [ $# -ge 1 ]; then
    ARCHIVE="$1"
else
    echo "用法: $0 <备份.tar.gz | --latest>" >&2
    exit 1
fi

if [ ! -f "$ARCHIVE" ]; then
    echo "找不到备份: $ARCHIVE" >&2
    exit 1
fi

echo "将恢复: $ARCHIVE"
echo "目标 Application Support: $APP_SUPPORT"
echo "目标 Preferences: $PREFS_DIR"
echo ""
echo "⚠ 会覆盖当前模板与设置。恢复前先自动备份当前数据。"
read -r -p "继续？[y/N] " ans
case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消"; exit 0 ;;
esac

echo ""
echo "━━━ 0/3 安全备份当前数据 ━━━"
./scripts/backup-userdata.sh --label pre-restore

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rp-userdata-restore.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo ""
echo "━━━ 1/3 解压备份 ━━━"
tar -xzf "$ARCHIVE" -C "$STAGE"

# 新格式: ReceiptPrinter/ + Preferences/ + MANIFEST.txt
# 旧格式: 顶层即为 ReceiptPrinter/（模板等）
if [ ! -d "$STAGE/ReceiptPrinter" ]; then
    echo "备份格式无法识别（缺少 ReceiptPrinter/）" >&2
    ls -la "$STAGE" >&2 || true
    exit 1
fi

echo ""
echo "━━━ 2/3 恢复 Application Support ━━━"
mkdir -p "$APP_SUPPORT"
rsync -a --exclude '.DS_Store' "$STAGE/ReceiptPrinter/" "$APP_SUPPORT/"
echo "已同步到 $APP_SUPPORT"

echo ""
echo "━━━ 3/3 恢复 Preferences ━━━"
if [ -d "$STAGE/Preferences" ]; then
    restored=0
    for plist in "$STAGE"/Preferences/*.plist; do
        [ -f "$plist" ] || continue
        base="$(basename "$plist")"
        dest="${PREFS_DIR}/${base}"
        cp -p "$plist" "$dest"
        echo "  + $base → $dest"
        restored=1
    done
    if [ "$restored" -eq 0 ]; then
        echo "  · 备份中无 Preferences plist"
    fi
else
    echo "  · 此备份不含 Preferences/（旧格式），设置项仍用当前机器上的值"
fi

if [ -f "$STAGE/MANIFEST.txt" ]; then
    echo ""
    echo "── MANIFEST ──"
    head -20 "$STAGE/MANIFEST.txt"
fi

echo ""
echo "完成。请重启 ReceiptPrinter.app 以加载恢复后的配置。"
