#!/bin/zsh
# ファイル（zip・DMG）を Apple の公証に出して待ち、通れば提出 ID を標準出力に出す。通らなければ理由のログを出して 0 以外で終わる
# 使い方: SUBMISSION=$(scripts/notarize.sh <ファイル>)
#   build-release.sh（アプリ）と make-dmg.sh（DMG）から呼ぶ。staple は呼んだ側で行う（staple する先が、出したファイルと違うことがあるため）
#   資格情報は次のどちらか（build-release.sh の頭の説明と同じ）
#     - キーチェーンのプロファイル（既定）。名前は NOTARY_PROFILE で指定できる
#     - scripts/notary.env（あればこちらを使う。scripts/notary.env.example を写して値を埋める。.gitignore の対象で、コミットしない）
set -euo pipefail

FILE=${1:?使い方: scripts/notarize.sh <ファイル>}
ENV_FILE="${0:A:h}/notary.env"
PROFILE=${NOTARY_PROFILE:-screentextcapture-notary}

if [[ -f "$ENV_FILE" ]]; then
  # export しない。値は notarytool の引数にだけ使う（子プロセスの環境やログに写さないため）
  source "$ENV_FILE"
  # 妥協: パスワードを引数で渡すため、待つ数分の間は ps から見える。共用の Mac では、キーチェーンのプロファイルを使う
  CREDENTIALS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  CREDENTIALS=(--keychain-profile "$PROFILE")
fi

echo "公証に出しています（数分かかることがあります）: ${FILE:t}" >&2
RESULT=$(xcrun notarytool submit "$FILE" "${CREDENTIALS[@]}" --wait --output-format json)
STATUS=$(print -r -- "$RESULT" | plutil -extract status raw - 2>/dev/null || echo 不明)
SUBMISSION=$(print -r -- "$RESULT" | plutil -extract id raw - 2>/dev/null || echo "")
if [[ "$STATUS" != Accepted ]]; then
  echo "公証が通りませんでした（${FILE:t}・$STATUS）。理由:" >&2
  [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" "${CREDENTIALS[@]}" >&2
  exit 1
fi
print -r -- "$SUBMISSION"
