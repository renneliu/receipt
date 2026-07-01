#!/bin/bash
# 发版一条龙：改版本号 → 打包 → 提交 Git → 打标签
#
# 用法:
#   ./scripts/release.sh patch "修复电影票片名太小"
#   ./scripts/release.sh minor "新增某某功能"
#   ./scripts/release.sh build "仅测试打包，版本 build+1"
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

echo "━━━ 1/4 更新版本号 ━━━"
./scripts/bump-version.sh "$KIND"
# shellcheck source=version-lib.sh
source scripts/version-lib.sh
read_version
TAG="v${MARKETING_VERSION}"

echo ""
echo "━━━ 2/4 打包正式版 ━━━"
./scripts/build-app.sh

echo ""
echo "━━━ 3/4 提交到 Git ━━━"
git add -A
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
echo "━━━ 4/4 推送到 GitHub ━━━"
echo "请执行（或复制到终端）："
echo ""
echo "  git push origin main"
echo "  git push origin ${TAG}"
echo ""
echo "完成！应用版本: ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "安装包: dist/ReceiptPrinter.app"
echo ""
echo "记得在 CHANGELOG.md 顶部补一行本次更新说明。"
