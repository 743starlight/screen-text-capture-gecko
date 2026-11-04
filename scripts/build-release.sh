#!/bin/zsh
# 配布用の ScreenTextCapture Gecko を作る。コミットした内容だけでビルドし、Developer ID で署名して Apple の公証を受け、
# staple してから dist/ScreenTextCapture-Gecko-<版>.zip とその SHA-256 を作る（/Applications へは入れない）
# 使い方: scripts/build-release.sh
#   署名: キーチェーンにある Developer ID Application の証明書。名前は SIGN_IDENTITY で指定できる
#   公証の資格情報は次のどちらか
#     - キーチェーンのプロファイル（既定）。一度だけ登録する:
#         xcrun notarytool store-credentials screentextcapture-notary --apple-id <Apple ID> --team-id <チーム ID>
#       別の名前で登録したときは NOTARY_PROFILE で指定する
#     - scripts/notary.env（scripts/notary.env.example を写して値を埋める。.gitignore の対象で、コミットしない）
set -euo pipefail

ROOT=${0:A:h:h}
ENV_FILE="$ROOT/scripts/notary.env"
DIST="$ROOT/dist"
# 作っている途中のものは /tmp に置き、公証まで通ったものだけを dist/ へ置く（失敗したときに前の配布物を消さないため）
SNAP=/tmp/screentextcapture-release-snap
DD=/tmp/screentextcapture-release-dd
STAGE=/tmp/screentextcapture-release-out
IDENTITY=${SIGN_IDENTITY:-Developer ID Application}
PROFILE=${NOTARY_PROFILE:-screentextcapture-notary}

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
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"

# 出す前に、公証で断られる形でないかを確かめる
codesign --verify --strict --deep "$APP"
SIGN_INFO=$(codesign -dv --verbose=2 "$APP" 2>&1)
[[ "$SIGN_INFO" == *"Authority=Developer ID Application"* ]] || { echo 'Developer ID で署名されていないため中止' >&2; exit 1; }
[[ "$SIGN_INFO" == *"Timestamp="* ]] || { echo '署名に時刻が付いていないため中止' >&2; exit 1; }
[[ "$SIGN_INFO" == *flags=*runtime* ]] || { echo 'Hardened Runtime が無効なため中止' >&2; exit 1; }
[[ "$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" != *get-task-allow* ]] || { echo 'get-task-allow が残っているため中止' >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

# 公証に出して結果を待つ（Apple の手引きどおり zip で出す）。通らなければ理由のログを出して止まる
SUBMIT="$STAGE/notarize.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
if [[ -f "$ENV_FILE" ]]; then
  # export しない。値は notarytool の引数にだけ使う（子プロセスの環境やログに写さないため）
  source "$ENV_FILE"
  # 妥協: パスワードを引数で渡すため、待つ数分の間は ps から見える。共用の Mac では、キーチェーンのプロファイルを使う
  CREDENTIALS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  CREDENTIALS=(--keychain-profile "$PROFILE")
fi
echo "公証に出しています（数分かかることがあります）: ScreenTextCapture Gecko $VERSION（$COMMIT）" >&2
RESULT=$(xcrun notarytool submit "$SUBMIT" "${CREDENTIALS[@]}" --wait --output-format json)
STATUS=$(print -r -- "$RESULT" | plutil -extract status raw - 2>/dev/null || echo 不明)
SUBMISSION=$(print -r -- "$RESULT" | plutil -extract id raw - 2>/dev/null || echo "")
if [[ "$STATUS" != Accepted ]]; then
  echo "公証が通りませんでした（$STATUS）。理由:" >&2
  [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" "${CREDENTIALS[@]}" >&2
  exit 1
fi
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
echo "できあがり: $ZIP（コミット $COMMIT・公証の提出 ID $SUBMISSION）"
cat "$ZIP.sha256"
