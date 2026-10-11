#!/usr/bin/env bash
# 一键构建脚本：版本号的唯一来源是 pubspec.yaml 的 `version` 字段。
# 脚本自动把它取出并注入 --dart-define=APP_VERSION，避免手动传值漂移
# （之前 pubspec 的 version 与手传的 APP_VERSION 两处定义，容易对不上）。
#
# 用法（在 Git Bash / Linux / macOS 终端执行）：
#   ./tool/build.sh            # 同时构建 apk 与 windows
#   ./tool/build.sh apk        # 仅 Android apk
#   ./tool/build.sh windows    # 仅 Windows exe
#
# 注：windows 构建需要本机已安装 Visual Studio（含「桌面开发」工作负载）；
# apk 构建需要 Android SDK。脚本只负责注入版本号，不替你装工具链。
set -euo pipefail

# 切到仓库根目录（脚本位于 <repo>/tool/）
cd "$(dirname "$0")/.."

# 从 pubspec.yaml 提取版本号，形如 `version: 1.2.3+4` 只取 `1.2.3`。
VERSION="$(grep -m1 '^version:' pubspec.yaml | sed -E 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
if [ -z "$VERSION" ]; then
  echo "ERROR: 无法从 pubspec.yaml 解析 version" >&2
  exit 1
fi
echo "Building with APP_VERSION=$VERSION"

TARGET="${1:-all}"

build_apk() {
  echo "==> flutter build apk --release"
  flutter build apk --release --target-platform android-arm64 --dart-define=APP_VERSION="$VERSION"
}

build_windows() {
  echo "==> flutter build windows --release"
  flutter build windows --release --dart-define=APP_VERSION="$VERSION"
}

case "$TARGET" in
  apk) build_apk ;;
  windows|win) build_windows ;;
  all)
    build_apk
    build_windows
    ;;
  *)
    echo "Usage: $0 [apk|windows|all]" >&2
    exit 1
    ;;
esac
