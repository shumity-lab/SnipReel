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
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-snipreel-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

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
shasum -a 256 "$DMG"
echo "完成: $DMG"
