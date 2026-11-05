#!/bin/zsh
# 配布用の ScreenTextCapture Gecko を作る。コミットした内容だけでビルドし、Developer ID で署名して Apple の公証を受け、
# staple してから dist/ScreenTextCapture-Gecko-<版>.zip（GitHub のリリース用）とその SHA-256、自動アップデート（Sparkle）が読む
# dist/appcast.xml を作る（/Applications へは入れない。GitHub のリリースには、この3つを添付する）。
# 続けて scripts/make-dmg.sh で、紹介ページで配る dist/ScreenTextCapture-Gecko-<版>.dmg も作る
# 使い方: scripts/build-release.sh
#   署名: キーチェーンにある Developer ID Application の証明書。名前は SIGN_IDENTITY で指定できる
#   自動アップデートの署名: ログインキーチェーンの Sparkle の鍵（アカウント screentextcapture-gecko）。名前は SPARKLE_ACCOUNT で指定できる。
#     初めて使うときは、キーチェーンが鍵を使ってよいかを尋ねる
#   公証の資格情報は次のどちらか
#     - キーチェーンのプロファイル（既定）。一度だけ登録する:
#         xcrun notarytool store-credentials screentextcapture-notary --apple-id <Apple ID> --team-id <チーム ID>
#       別の名前で登録したときは NOTARY_PROFILE で指定する
#     - scripts/notary.env（scripts/notary.env.example を写して値を埋める。.gitignore の対象で、コミットしない）
set -euo pipefail

ROOT=${0:A:h:h}
DIST="$ROOT/dist"
# 作っている途中のものは /tmp に置き、公証まで通ったものだけを dist/ へ置く（失敗したときに前の配布物を消さないため）
SNAP=/tmp/screentextcapture-release-snap
DD=/tmp/screentextcapture-release-dd
STAGE=/tmp/screentextcapture-release-out
IDENTITY=${SIGN_IDENTITY:-Developer ID Application}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-screentextcapture-gecko}

cd /tmp

# コミットした内容だけで作る（コミットしていない変更を配布物に混ぜない）
rm -rf "$SNAP" "$STAGE"
mkdir -p "$SNAP" "$STAGE"
git -C "$ROOT" archive HEAD | tar -x -C "$SNAP"
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)

# ad-hoc で作ってから、Developer ID・Hardened Runtime・時刻付きで署名し直す。
# アプリは特別な権限（entitlements）を使わないため、署名し直しで get-task-allow なども残らない
xcodebuild -project "$SNAP/screentextcapture.xcodeproj" -scheme screentextcapture -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" -quiet CODE_SIGN_IDENTITY=- build
APP="$STAGE/ScreenTextCapture Gecko.app"
ditto "$DD/Build/Products/Release/ScreenTextCapture Gecko.app" "$APP"
SPARKLE_ARTIFACT="$DD/SourcePackages/artifacts/sparkle/Sparkle"
# 配る版には、使っているコードの許諾文を入れる（MIT などは、写しに著作権表示と許諾文を含めることを求めるため）。
# このアプリの LICENSE（元の ku/screentextcapture を含む）と、Sparkle の LICENSE（Sparkle が使う bsdiff などの許諾文を含む）
cp "$SNAP/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$SPARKLE_ARTIFACT/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
# 自動アップデート（Sparkle）の中の補助プログラム（XPC サービス・Autoupdate・Updater.app）は ad-hoc の署名のまま届き、
# このままでは公証で断られる。内側から順に Developer ID・Hardened Runtime・時刻付きで署名し直し、最後にアプリを署名し直す
# （Sparkle の文書の手順。mynah と同じ）
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for part in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements "$SPARKLE/Versions/Current/$part"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$SPARKLE"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"

# 出す前に、公証で断られる形でないかを確かめる
codesign --verify --strict --deep "$APP"
SIGN_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1)
[[ "$SIGN_INFO" == *"Authority=Developer ID Application"* ]] || { echo 'Developer ID で署名されていないため中止' >&2; exit 1; }
[[ "$SIGN_INFO" == *"Timestamp="* ]] || { echo '署名に時刻が付いていないため中止' >&2; exit 1; }
[[ "$SIGN_INFO" == *flags=*runtime* ]] || { echo 'Hardened Runtime が無効なため中止' >&2; exit 1; }
[[ "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" != *get-task-allow* ]] || { echo 'get-task-allow が残っているため中止' >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")
# アプリは最新のリリースに添付した appcast.xml を読む（…/releases/latest/download/appcast.xml）。配布物はその版のリリースに置く
REPO_URL=${FEED%/releases/latest/download/appcast.xml}
[[ "$REPO_URL" != "$FEED" ]] || { echo "SUFeedURL が最新のリリースの appcast.xml を指していないため中止: $FEED" >&2; exit 1; }
# 鍵の取り違えを防ぐ。キーチェーンの Sparkle の鍵の公開鍵が、アプリに入れた SUPublicEDKey と同じでなければ、
# 配った版が自分の更新を受け付けなくなる
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
[[ "$("$SPARKLE_ARTIFACT/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p)" == "$PUBLIC_KEY" ]] \
  || { echo "キーチェーンの Sparkle の鍵（アカウント $SPARKLE_ACCOUNT）が、アプリの SUPublicEDKey と合わないため中止" >&2; exit 1; }

# 公証に出して結果を待つ（Apple の手引きどおり zip で出す）。通らなければ理由のログを出して止まる（scripts/notarize.sh。DMG と共通）
SUBMIT="$STAGE/notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
echo "公証に出すアプリ: ScreenTextCapture Gecko $VERSION（$COMMIT）" >&2
SUBMISSION=$("$ROOT/scripts/notarize.sh" "$SUBMIT")
rm -f "$SUBMIT"

# 公証の結果をアプリに付け（ネットにつながっていなくても Gatekeeper が確かめられるように）、Gatekeeper が通すことを確かめる
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# 配る zip と、その SHA-256 を dist/ に置く（版ごとに残す）
mkdir -p "$DIST"
ZIP="$DIST/ScreenTextCapture-Gecko-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")

# 自動アップデートの署名と、アプリが読む appcast.xml。秘密鍵はキーチェーンにあり、値はここに出ない。
# 代入で受けて、署名できなかったら set -e で止める（ヒアドキュメントの中に直に書くと、失敗しても先へ進むため）
ED_ATTRIBUTES=$("$SPARKLE_ARTIFACT/bin/sign_update" --account "$SPARKLE_ACCOUNT" "$ZIP")  # sparkle:edSignature="…" length="…"
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")
PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
APPCAST="$DIST/appcast.xml"
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ScreenTextCapture Gecko</title>
    <item>
      <title>ScreenTextCapture Gecko $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/${ZIP:t}" $ED_ATTRIBUTES type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST"
echo "できあがり: $ZIP と $APPCAST（コミット $COMMIT・公証の提出 ID $SUBMISSION）"
cat "$ZIP.sha256"

# 紹介ページで配る DMG（中は同じアプリ。DMG にも署名・公証・staple をし、Gatekeeper の確かめまで通す）
"$ROOT/scripts/make-dmg.sh" "$APP"
