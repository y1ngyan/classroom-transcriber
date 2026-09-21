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

# ---- Whisper（本地语音识别）----
#
# 用 brew 装的 whisper.cpp 动态库。链接它要三样东西：
#   1. module map：让 Swift 能 `import whisper`（whisper.h 是纯 C API）
#   2. -I：whisper.h 和它依赖的 ggml.h 的路径（ggml.h 在 /opt/homebrew/include）
#   3. -L/-l：libwhisper 和 ggml 系列
#
# 路径写死 brew 的前缀（/opt/homebrew）而不是调 `brew --prefix`：
# 构建脚本每次都要跑，起子进程查前缀会明显拖慢构建，而 brew 的默认
# 前缀是稳定的。Intel Mac 上前缀不同，那台机器需要改这里
WHISPER_PREFIX="/opt/homebrew"
WHISPER_INC="$WHISPER_PREFIX/Cellar/whisper.cpp/1.9.4/include"
MODULEMAP="$BUILD_DIR/whisper.modulemap"

mkdir -p "$BUILD_DIR"
cat > "$MODULEMAP" <<MAP
module whisper [system] {
    header "$WHISPER_INC/whisper.h"
    link "whisper"
    export *
}
MAP

if [ ! -f "$WHISPER_INC/whisper.h" ]; then
  echo "⚠️  找不到 whisper.h（$WHISPER_INC）"
  echo "   本地 Whisper 功能将不可用。安装：brew install whisper-cpp"
fi

swiftc \
  -sdk "$SDK_PATH" \
  -target "$TARGET" \
  -swift-version 6 \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework Speech \
  -framework AVFoundation \
  -Xcc -fmodule-map-file="$MODULEMAP" \
  -I "$WHISPER_INC" \
  -I "$WHISPER_PREFIX/include" \
  -L "$WHISPER_PREFIX/lib" -lwhisper -lggml -lggml-base \
  -Xlinker -rpath -Xlinker "$WHISPER_PREFIX/lib" \
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
