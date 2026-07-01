#!/bin/bash
# 读取项目根目录 VERSION 文件：第 1 行=对外版本，第 2 行=构建号

version_file() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION"
}

read_version() {
    local file
    file="$(version_file)"
    MARKETING_VERSION="$(sed -n '1p' "$file" | tr -d '[:space:]')"
    BUILD_NUMBER="$(sed -n '2p' "$file" | tr -d '[:space:]')"
    export MARKETING_VERSION BUILD_NUMBER
}

write_version() {
    local file
    file="$(version_file)"
    printf '%s\n%s\n' "$MARKETING_VERSION" "$BUILD_NUMBER" > "$file"
}
