#!/bin/zsh
# 公証済みのアプリから、紹介ページで配る DMG を作る（build-release.sh の最後でも呼ぶ）
# 使い方: scripts/make-dmg.sh <公証済みのアプリ（.app）か、それを入れた zip> [--preview]
#   開くと、ScreenTextCapture Gecko と「Applications」へのリンクが並び、背景の矢印と手順で、ドラッグして入れることと、アプリケーションフォルダから起動することが分かる窓になる。
#   背景の絵は、作るたびに scripts/dmg-background.swift で描く（字が Mac の標準の字体なので、Mac で描く）。
#   窓の大きさ・アイコンの大きさと位置・背景の指定は、scripts/dmg-dsstore.swift で DMG の中の .DS_Store に書く（Finder は操作しない）。
#   DMG にも Developer ID で署名し、公証に出して staple する（資格情報は build-release.sh と同じ）。最後に check-gatekeeper.sh を通す。
#   zip で配ると、Chrome が「一般的にダウンロードされているファイルではない」と止めることがあるため、紹介ページでは DMG で配る
#   --preview: 署名も公証もせず、作った DMG を開いて見せるだけ（見た目を直すとき。dist には置かない）
#   出来上がり: dist/ScreenTextCapture-Gecko-<版>.dmg とその SHA-256
set -euo pipefail

PREVIEW=0
SOURCE=""
for arg in "$@"; do
  case $arg in
    --preview) PREVIEW=1 ;;
    *) SOURCE=$arg ;;
  esac
done
[[ -n $SOURCE ]] || { echo '使い方: scripts/make-dmg.sh <公証済みのアプリ（.app）か、それを入れた zip> [--preview]' >&2; exit 2; }
SOURCE=${SOURCE:A}
ROOT=${0:A:h:h}
DIST="$ROOT/dist"
APP_NAME="ScreenTextCapture Gecko.app"
VOLUME="ScreenTextCapture Gecko"
IDENTITY=${SIGN_IDENTITY:-Developer ID Application}
# 窓の中の大きさ（背景の絵と同じ。pt）と、アイコンの中心。背景の絵と .DS_Store を書くときに、同じ数を渡す
# 高さは、パスバーやステータスバーを表示している Mac で窓の下が隠れても、背景の手順の下に余白が残るようにとる
WIDTH=660
HEIGHT=480
APP_X=170
LINK_X=490
ICON_Y=200

# 作るものは /tmp に置き、出来上がりだけを dist/ へ移す
cd /tmp
# 作る DMG を /Volumes/ScreenTextCapture Gecko に開いて書き込むので、同じ名前のディスクが開いていると、別の場所に開いて取り違える
[[ ! -e "/Volumes/$VOLUME" ]] || { echo "中止: 「$VOLUME」という名前のディスクが開いています。取り出してから、もう一度実行してください" >&2; exit 1; }

STAGE=$(mktemp -d /tmp/screentextcapture-dmg.XXXXXX)
MOUNT=""
trap '[[ -n $MOUNT ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null; rm -rf "$STAGE"' EXIT

# zip を渡されたら（GitHub のリリースに置いた配布物など）、中のアプリを取り出して使う
if [[ ${SOURCE:e} == zip ]]; then
  ditto -x -k "$SOURCE" "$STAGE/unzipped"
  APP="$STAGE/unzipped/$APP_NAME"
else
  APP=$SOURCE
fi
[[ -d "$APP" && ${APP:t} == "$APP_NAME" ]] || { echo "中止: $APP_NAME が見つかりません（$SOURCE）" >&2; exit 1; }
# 公証と staple の済んだアプリだけを入れる
xcrun stapler validate "$APP" >/dev/null
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")

mkdir -p "$STAGE/root/.background"
# 拡張属性は入れない（「._」のファイルがアプリに残ると、Gatekeeper に止められる）
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/root/$APP_NAME"
ln -s /Applications "$STAGE/root/Applications"
# 背景の絵。等倍と2倍を1つの TIFF にまとめ、Retina の Mac でもにじまないようにする。マークは README のアイコン（公開用にもある素材）
xcrun swift "$ROOT/scripts/dmg-background.swift" "$STAGE/root/.background/background.tiff" "$ROOT/.github/assets/icon.png" \
  $WIDTH $HEIGHT $APP_X $LINK_X $ICON_Y

# 書き込める DMG を作って開き、窓の設定（.DS_Store）を書く。背景の絵を指すしおりは、開いたディスクの中のファイルから作る。
# Finder は操作しない（AppleScript で決めさせると、macOS 26 ではアイコンの大きさと背景が残らなかった。理由は dmg-dsstore.swift）
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE/root" -fs HFS+ -format UDRW -ov -quiet "$STAGE/rw.dmg"
hdiutil attach "$STAGE/rw.dmg" -readwrite -noverify -noautoopen -quiet
MOUNT="/Volumes/$VOLUME"
xcrun swift "$ROOT/scripts/dmg-dsstore.swift" "$MOUNT" "$APP_NAME" $WIDTH $HEIGHT $APP_X $LINK_X $ICON_Y
rm -rf "$MOUNT/.fseventsd"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

DMG="$STAGE/ScreenTextCapture-Gecko-$VERSION.dmg"
hdiutil convert "$STAGE/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet

if (( PREVIEW )); then
  PREVIEW_DMG="/tmp/ScreenTextCapture-Gecko-$VERSION-preview.dmg"
  mv -f "$DMG" "$PREVIEW_DMG"
  open "$PREVIEW_DMG"
  echo "見本: $PREVIEW_DMG（署名・公証なし。配らない）"
  exit 0
fi

codesign --force --sign "$IDENTITY" --timestamp "$DMG"
SUBMISSION=$("$ROOT/scripts/notarize.sh" "$DMG")
xcrun stapler staple "$DMG"

mkdir -p "$DIST"
OUT="$DIST/ScreenTextCapture-Gecko-$VERSION.dmg"
mv -f "$DMG" "$OUT"
(cd "$DIST" && shasum -a 256 "${OUT:t}" > "${OUT:t}.sha256")
# 通らなければここで止まる（配るたびに必ず通す）
"$ROOT/scripts/check-gatekeeper.sh" "$OUT"
echo "公証済み: $OUT（$VERSION・ビルド $BUILD・公証の提出 ID $SUBMISSION）"
cat "$OUT.sha256"
