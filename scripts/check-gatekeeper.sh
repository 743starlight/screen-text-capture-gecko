#!/bin/zsh
# 配る DMG が、使う人の Mac で Gatekeeper に通るかを確かめる（make-dmg.sh の最後でも呼ぶ。配るたびに必ず通す）
# 使い方: scripts/check-gatekeeper.sh <DMG のパス、または https の URL>
#   DMG そのものの署名・Gatekeeper の判定（開くときの判定）・staple を確かめ、ダウンロードの印を付けて開き、
#   中のアプリと、「アプリケーション」へドラッグしたのと同じく取り出したアプリを確かめる。
#   アプリはどれも codesign（strict・deep）・spctl（Gatekeeper）・stapler・syspolicy_check distribution を通す。
#   1つでも通らなければ 0 以外で終わる。URL を渡すと本番から取り直すので、紹介ページに出したものそのものを確かめられる
set -euo pipefail

SOURCE=${1:?使い方: scripts/check-gatekeeper.sh <DMG のパス、または https の URL>}
[[ $SOURCE == https://* ]] || SOURCE=${SOURCE:A}
[[ ${SOURCE:e} == dmg ]] || { echo "中止: .dmg を渡してください（$SOURCE）" >&2; exit 1; }
APP_NAME="ScreenTextCapture Gecko.app"
# 確かめに使うものは /tmp に置き、終わったら消す
WORK=$(mktemp -d /tmp/screentextcapture-gatekeeper.XXXXXX)
MOUNT=""
trap '[[ -n $MOUNT ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null; rm -rf "$WORK"' EXIT
cd "$WORK"

FILE="$WORK/download.dmg"
if [[ $SOURCE == https://* ]]; then
  curl -fsSL --max-time 300 -o "$FILE" "$SOURCE"
else
  cp "$SOURCE" "$FILE"
fi
echo "確かめるファイル: $SOURCE（$(stat -f %z "$FILE") バイト・SHA-256 $(shasum -a 256 "$FILE" | cut -d' ' -f1)）"

# アプリを確かめる。spctl は Gatekeeper と同じ判定で、通らなければ 0 以外で終わる
check() {
  local app=$1 label=$2 result
  codesign --verify --strict --deep "$app"
  spctl -a -vv "$app"
  xcrun stapler validate "$app" >/dev/null
  result=$(syspolicy_check distribution "$app" 2>&1) || true
  if [[ $result != *"ready for distribution"* ]]; then
    print -r -- "$result" >&2
    echo "中止: $label のアプリが syspolicy_check に通りません" >&2
    exit 1
  fi
  echo "通過: $label"
}

# DMG そのもの。開くときの判定は「open」の種類で、署名と公証（staple）を見る
codesign --verify --strict "$FILE"
spctl -a -t open --context context:primary-signature -vv "$FILE"
xcrun stapler validate "$FILE" >/dev/null
echo "通過: DMG の署名・Gatekeeper・staple"
# ブラウザでダウンロードしたときと同じ印を付けて開く
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;" "$FILE"
MOUNT="$WORK/mount"
mkdir "$MOUNT"
hdiutil attach "$FILE" -nobrowse -readonly -mountpoint "$MOUNT" -quiet
[[ -L "$MOUNT/Applications" ]] || { echo '中止: DMG に「アプリケーション」へのリンクがありません' >&2; exit 1; }
# 拡張属性の「._」のファイルがあると、取り出したアプリに残って Gatekeeper に止められる
ENTRIES=$(find "$MOUNT" -name '._*')
[[ -z $ENTRIES ]] || { echo '中止: DMG に拡張属性の「._」のファイルが入っています' >&2; exit 1; }
check "$MOUNT/$APP_NAME" "DMG の中"
# 「アプリケーション」へドラッグしたのと同じく、取り出して確かめる
mkdir dragged
ditto "$MOUNT/$APP_NAME" "dragged/$APP_NAME"
check "dragged/$APP_NAME" "DMG から取り出した形"
hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo "Gatekeeper の確かめ: すべて通りました"
