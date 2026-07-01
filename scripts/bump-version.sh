#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=version-lib.sh
source scripts/version-lib.sh
read_version

MODE="${1:-build}"

bump_build() {
    BUILD_NUMBER=$((BUILD_NUMBER + 1))
}

bump_semver() {
    local part="$1"
    IFS='.' read -r major minor patch <<< "$MARKETING_VERSION"
    major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
    case "$part" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "未知类型: $part" >&2; exit 1 ;;
    esac
    MARKETING_VERSION="${major}.${minor}.${patch}"
    bump_build
}

case "$MODE" in
    build)
        bump_build
        ;;
    patch|minor|major)
        bump_semver "$MODE"
        ;;
    show)
        echo "版本: ${MARKETING_VERSION}"
        echo "构建: ${BUILD_NUMBER}"
        exit 0
        ;;
    *)
        echo "用法: $0 [build|patch|minor|major|show]" >&2
        echo "  build  只增加构建号（默认，每次打包前常用）" >&2
        echo "  patch  修 bug：1.0.0 → 1.0.1" >&2
        echo "  minor  新功能：1.0.0 → 1.1.0" >&2
        echo "  major  大改版：1.0.0 → 2.0.0" >&2
        echo "  show   查看当前版本" >&2
        exit 1
        ;;
esac

write_version
echo "已更新 VERSION → ${MARKETING_VERSION} (build ${BUILD_NUMBER})"
