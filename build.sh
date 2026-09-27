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

# ---- 说话人识别 helper（FluidAudio）----
#
# helper 是**独立的 SwiftPM 包**（Vendor/DiarizeHelper），依赖 Vendor/FluidAudio
# ——一个钉住 commit 的 git submodule。它不并进主 App 那次 swiftc：FluidAudio 只
# 对外提供 SwiftPM 包、没有 modulemap，而主 App 是手工 swiftc 拼的，两边依赖管理
# 方式不同；硬凑到一起只会把「主 App 编不过」和「helper 编不过」搅成同一个错误。
#
# 这里的每一条都是**硬失败**。静默跳过是本项目最忌讳的失败模式：跳过之后 App 照样
# 能起、能录、能转录，只有「识别说话人」永远悄悄不工作——而那时人已经在怀疑
# 模型和音频了（C-3-1 派单第 1 条原话）。
HELPER_PKG="Vendor/DiarizeHelper"
HELPER_SUBMODULE="Vendor/FluidAudio"

helper_fail() {
  echo "❌ 说话人识别 helper 构建前提不满足：$1" >&2
  echo "" >&2
  echo "   补法（在仓库根目录跑）：" >&2
  echo "     git submodule update --init --recursive" >&2
  echo "" >&2
  echo "   它会按 .gitmodules 记的上游拉 FluidAudio 并检出钉住的 commit。" >&2
  echo "   仓库里没有 FluidAudio 的副本，也没有「退化成 path 本地依赖」这个选项：" >&2
  echo "   少这一块，「识别说话人」就不该能跑起来。" >&2
  exit 1
}

# ① 它得真是个 submodule。先看 .gitmodules 而不是先看目录：目录在、但没有
#    .gitmodules，说明有人把 clone 直接拷进来了，那种副本不受钉版保护
if [ ! -f .gitmodules ] || ! grep -q "path = $HELPER_SUBMODULE" .gitmodules; then
  # 变量一律写成 `${X}`：紧跟全角括号时 `$X（` 会被 bash 当成变量名的一部分
  # （UTF-8 locale 下多字节字符算标识符字符），表现是 `set -u` 下的
  # 「HELPER_SUBMODULE（…: unbound variable」——**提示信息本身没了**，
  # 只剩退出码非 0。这条是 2026-09-27 实测踩到的，别改回去
  helper_fail ".gitmodules 里没有 ${HELPER_SUBMODULE}（不是 git submodule）"
fi

# ② 得检出到工作区。submodule 没 init 时目录是空的——这一步把「没拉」和
#    「拉了但没检出」一起挡住
if [ ! -f "$HELPER_SUBMODULE/Package.swift" ]; then
  helper_fail "$HELPER_SUBMODULE 是空的（submodule 没检出）"
fi

# ③ 工作区的 HEAD 必须就是父仓库钉的那个 commit。submodule 是可以被单独
#    checkout 到别的 commit 的（甚至误 `git pull`），那时父仓库只会显示一行
#    "new commits"，而构建会照跑——**钉版就白钉了**。gitlink 是钉版的唯一真相
GITLINK=$(git ls-files -s "$HELPER_SUBMODULE" 2>/dev/null | awk '{print $1, $2}' || true)
if [ -z "$GITLINK" ] || [ "${GITLINK%% *}" != "160000" ]; then
  helper_fail "$HELPER_SUBMODULE 没有被父仓库记录成 gitlink（跑 git add $HELPER_SUBMODULE）"
fi
PINNED_SHA="${GITLINK##* }"
CHECKED_OUT_SHA=$(git -C "$HELPER_SUBMODULE" rev-parse HEAD 2>/dev/null || echo "")
if [ "$CHECKED_OUT_SHA" != "$PINNED_SHA" ]; then
  helper_fail "$HELPER_SUBMODULE 的 HEAD 是 ${CHECKED_OUT_SHA:0:12}，钉的是 ${PINNED_SHA:0:12}"
fi

# ④ 增量构建。swift build 自己就是增量的（FluidAudio 那几百个源文件只有第一次
#    要全编，之后改 helper 只重编 helper），所以这里不需要另做缓存判断
echo "▶ 构建 diarize-helper（首次要编 FluidAudio，分钟级；之后是增量的）…"
HELPER_START=$(date +%s)
# 显式取管道第一段的退出码，不靠 `set -o pipefail` + `!` 去兜：
# 那种写法在「有人改了 set 那行」时会变成「永远成功」，而失败分支永远不进
swift build -c release --package-path "$HELPER_PKG" 2>&1 | sed 's/^/  /' || true
HELPER_BUILD_STATUS=${PIPESTATUS[0]}
if [ "$HELPER_BUILD_STATUS" -ne 0 ]; then
  helper_fail "swift build 失败（退出码 $HELPER_BUILD_STATUS，输出在上）"
fi
HELPER_BIN_DIR=$(swift build -c release --package-path "$HELPER_PKG" --show-bin-path)
HELPER_BIN="$HELPER_BIN_DIR/diarize-helper"
if [ ! -x "$HELPER_BIN" ]; then
  helper_fail "构建跑完了但没有产出 $HELPER_BIN"
fi
HELPER_SECONDS=$(( $(date +%s) - HELPER_START ))

# ⑤ 放进 bundle 的 Contents/MacOS/（`Bundle.main.url(forAuxiliaryExecutable:)`
#    按定义要找的地方，也是主可执行文件所在处）。**必须在 codesign 之前**，
#    否则它不在签名覆盖范围内——和图标是同一条规矩
cp "$HELPER_BIN" "$APP_BUNDLE/Contents/MacOS/diarize-helper"
HELPER_SIZE=$(stat -f%z "$APP_BUNDLE/Contents/MacOS/diarize-helper")
echo "  helper: FluidAudio@${PINNED_SHA:0:12} → Contents/MacOS/diarize-helper · ${HELPER_SIZE} 字节 · 本次这一步 ${HELPER_SECONDS}s（增量）"

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
