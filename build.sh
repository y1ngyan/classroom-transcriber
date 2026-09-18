#!/bin/bash
# 用 Command Line Tools 直接编译并组装 .app bundle（不依赖完整 Xcode）
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClassroomTranscriber"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
SDK_PATH="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos26.0"

echo "▶ SDK: $SDK_PATH"
echo "▶ 编译中…"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

SOURCES=$(find Sources -name '*.swift' | sort)

swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET" \
  -swift-version 6 \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework Speech \
  -framework AVFoundation \
  $SOURCES \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "▶ 写入 Info.plist…"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.asuka.classroomtranscriber</string>
    <key>CFBundleName</key><string>Classroom Transcriber</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>需要麦克风权限来录制课堂音频</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>需要语音识别来转录课堂内容</string>
</dict>
</plist>
PLIST

# 图标得赶在签名之前放进 bundle，否则它不在签名覆盖的范围内
ICON_SCRIPT="tools/make_icon.swift"
ICON_FILE="build/icon/AppIcon.icns"
if [ ! -f "$ICON_FILE" ] || [ "$ICON_SCRIPT" -nt "$ICON_FILE" ]; then
  echo "▶ 生成图标…"
  swift "$ICON_SCRIPT" | sed 's/^/  /'
fi
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

echo "▶ 签名（ad-hoc）…"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" 2>&1 | sed 's/^/  /'

echo "✅ 构建完成: $APP_BUNDLE"
