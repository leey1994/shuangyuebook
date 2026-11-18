#!/usr/bin/env bash
# 本地构建 APK：版本号必须与 pubspec 一致地传进 APP_VERSION，
# 否则安装器显示 pubspec 版本、应用内显示编译期默认值 —— 两个版本号对不上。
# 用法：bash tool/build_apk.sh [--split-per-abi]
set -euo pipefail
cd "$(dirname "$0")/.."
V=$(grep -E '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
echo "APP_VERSION=$V (pubspec: $(grep -E '^version:' pubspec.yaml | awk '{print $2}'))"
flutter build apk --release --dart-define=APP_VERSION="$V" "$@"
