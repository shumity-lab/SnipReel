#!/bin/bash
# SnipReel.app をビルドして build/ に出力する
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
python3 scripts/gen-strings.py
# UNIVERSAL=1 で Apple シリコン + Intel 両対応のバイナリを作る(配布用)
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/SnipReel"

APP="build/SnipReel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SnipReel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
cp -R Resources/en.lproj Resources/ja.lproj "$APP/Contents/Resources/"

# 自動アップデート用の Sparkle.framework を同梱する
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
# サンドボックス化していないアプリでは XPC サービスは不要
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SnipReel"

# 署名: SIGN_IDENTITY 指定 > キーチェーンの開発者証明書 > アドホック
# (証明書で署名すると、再ビルドしても「画面収録」の許可が維持される)
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E '"(Apple Development|Developer ID Application)' | head -1 \
    | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/')"
fi
# RELEASE=1 で公証に必要なハードンドランタイムとタイムスタンプを付ける
SIGN_FLAGS=()
if [ "${RELEASE:-0}" = "1" ]; then SIGN_FLAGS=(--options runtime --timestamp); fi
# Sparkle の中身 → フレームワーク → アプリ本体の順に署名する(内側から)
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
  codesign --force --sign "${IDENTITY:--}" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$item"
done
codesign --force --sign "${IDENTITY:--}" --entitlements Resources/SnipReel.entitlements \
  ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$APP"
echo "Built: $APP (signed with: ${IDENTITY:-ad-hoc})"
