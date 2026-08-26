#!/bin/bash
# 发版一条龙：备份用户数据 → 改版本号 → 打包 → 提交 Git → 打标签
#
# 用法:
#   ./scripts/release.sh patch "修复电影票片名太小"
#   ./scripts/release.sh minor "新增某某功能"
#   ./scripts/release.sh build "仅测试打包，版本 build+1"
#
# Git 标签只管源代码；模板/设置在 Application Support，由 backup-userdata.sh
# 写入 backups/（gitignore，不进仓库）。
#
set -euo pipefail
cd "$(dirname "$0")/.."

KIND="${1:-patch}"
MESSAGE="${2:-}"

if [ -z "$MESSAGE" ]; then
    echo "用法: $0 <patch|minor|major|build> \"这次改了什么\"" >&2
    echo "示例: $0 patch \"修复打印乱码\"" >&2
    exit 1
fi

case "$KIND" in
    patch|minor|major|build) ;;
    *)
        echo "类型必须是 patch / minor / major / build" >&2
        exit 1
        ;;
esac

echo "━━━ 0/6 备份用户配置与模板 ━━━"
./scripts/backup-userdata.sh --label "pre-release-${KIND}"

echo ""
echo "━━━ 1/6 更新版本号 ━━━"
./scripts/bump-version.sh "$KIND"
# shellcheck source=version-lib.sh
source scripts/version-lib.sh
read_version
TAG="v${MARKETING_VERSION}"

echo ""
echo "━━━ 2/6 打包本地正式版 ━━━"
./scripts/build-app.sh

echo ""
echo "━━━ 3/6 同步发行版（Store）工程与构建 ━━━"
# 同一套 ReceiptPrinter/ 源码；重新生成 xcodeproj 写入 VERSION，并打 App Store 定义包
./scripts/generate-store-xcodeproj.sh
./scripts/build-appstore.sh

echo ""
echo "━━━ 4/6 再次备份（带新版本号） ━━━"
./scripts/backup-userdata.sh --label "release"

echo ""
echo "━━━ 5/6 提交到 Git ━━━"
git add -A
# userdata 压缩包在 .gitignore；不要误加
git reset -q -- backups/ReceiptPrinter-userdata-*.tar.gz 2>/dev/null || true
if git diff --cached --quiet; then
    echo "没有代码改动需要提交（仅 VERSION 可能已更新）"
    git add VERSION
fi
git commit -m "${TAG}: ${MESSAGE}" || {
    echo "没有新改动可提交，跳过 commit"
}

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "标签 $TAG 已存在，跳过打标签"
else
    git tag -a "$TAG" -m "${MESSAGE}"
    echo "已打标签 $TAG"
fi

echo ""
echo "━━━ 6/6 推送到 GitHub ━━━"
echo "请执行（或复制到终端）："
echo ""
echo "  git push origin main"
echo "  git push origin ${TAG}"
echo ""
echo "完成！应用版本: ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "本地包:   dist/ReceiptPrinter.app"
echo "发行包:   dist/ReceiptPrinterStore.app  （ad-hoc；上架请用 Xcode Archive）"
echo "用户数据备份: backups/ReceiptPrinter-userdata-*.tar.gz"
echo ""
echo "记得在 CHANGELOG.md 顶部补一行本次更新说明。"
echo "上架: open ReceiptPrinterStore.xcodeproj → Product → Archive"
