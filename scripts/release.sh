#!/bin/bash
# 配布用の DMG を作る: ユニバーサルビルド → Developer ID 署名 → DMG → 公証 → staple
#
# 事前準備(初回のみ。公証用の認証情報をキーチェーンに保存する):
#   xcrun notarytool store-credentials snipreel-notary \
#     --apple-id <Apple ID> --team-id <チームID> --password <アプリ用パスワード>
#
# 使い方:
#   ./scripts/release.sh                 # 公証まで行う
#   SKIP_NOTARIZE=1 ./scripts/release.sh # 公証せずに DMG だけ作る(動作確認用)
#
# リリースのたびに Resources/Info.plist の CFBundleShortVersionString(表示用)と
# CFBundleVersion(整数。Sparkle はこちらで新旧を比べる)を両方上げること。
# 自動アップデート用の appcast.xml は Sparkle の署名鍵(ログインキーチェーン)で署名する。
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-snipreel-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
REPO_URL="https://github.com/shumity-lab/SnipReel"

# 配布には Developer ID Application 証明書が必須
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep '"Developer ID Application' | head -1 | sed -E 's/^ *[0-9]+\) ([0-9A-F]+) .*/\1/')}"
if [ -z "$IDENTITY" ]; then
  echo "Developer ID Application 証明書が見つかりません" >&2
  exit 1
fi

UNIVERSAL=1 RELEASE=1 SIGN_IDENTITY="$IDENTITY" ./scripts/build-app.sh
APP="build/SnipReel.app"
codesign --verify --strict --deep "$APP"

# DMG(アプリ + 「アプリケーション」フォルダへのショートカット)
DMG="build/SnipReel-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "SnipReel $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "公証をスキップしました: $DMG"
  exit 0
fi

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# 自動アップデート用の appcast.xml(staple 後の DMG に署名する)
APPCAST_DIR="build/appcast"
rm -rf "$APPCAST_DIR"
mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
  --link "$REPO_URL" \
  "$APPCAST_DIR"

shasum -a 256 "$DMG"
echo "完成: $DMG"
echo "      $APPCAST_DIR/appcast.xml"
echo
echo "GitHub に公開するには(DMG と appcast.xml の両方を添付する):"
echo "  gh release create v$VERSION \"$DMG\" \"$APPCAST_DIR/appcast.xml\" --title \"SnipReel $VERSION\""
