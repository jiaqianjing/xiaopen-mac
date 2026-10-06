#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "🔨 正在使用 Swift 6 编译 Release 版本..."
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release

APP_NAME="XiaoPen"
BUNDLE_DIR="$DIR/build/$APP_NAME.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$DIR/.build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cp "$DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

echo "✅ 打包完成: $BUNDLE_DIR"
