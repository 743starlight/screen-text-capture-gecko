<p align="center">
  <img src=".github/assets/icon.png" width="128" height="128" alt="ScreenTextCapture Gecko のアイコン">
</p>

<h1 align="center">ScreenTextCapture Gecko</h1>

<p align="center">画面の好きな範囲を選ぶだけで、写っている文字を読み取ってクリップボードにコピーする macOS アプリ<br>
<sub><a href="https://github.com/ku/screentextcapture">ku/screentextcapture</a> をもとに作り直したフォークです</sub></p>

<p align="center">
  <a href="https://github.com/743starlight/screen-text-capture-gecko/releases/latest"><img alt="最新のリリース" src="https://img.shields.io/github/v/release/743starlight/screen-text-capture-gecko"></a>
  <img alt="macOS 14 以降" src="https://img.shields.io/badge/macOS-14%2B-blue">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

> **English:** ScreenTextCapture Gecko is a macOS menu bar app that recognizes the text in any area of the screen you select and copies it to the clipboard. Recognition runs on-device with Apple Vision by default, and ChatGPT (Codex CLI) or Claude Code CLI can optionally be used with your own subscription. It is a fork of [ku/screentextcapture](https://github.com/ku/screentextcapture). The user interface is in Japanese.

## 特長

- **すぐ始められる** — Dock のアイコン、ショートカット（⌥⇧⌘T）、メニューバーのどこからでも範囲選択を始められます。
- **Mac の中で完結** — 既定の Apple Vision は、画像を Mac の外へ送りません。日本語・英語・中国語（簡体字・繁体字）・韓国語に対応しています。
- **生成 AI でも読める** — ChatGPT（Codex CLI）・Claude Code CLI を、ご自身の契約のログインで使えます。API キーは要りません。
- **控えめに知らせる** — コピーの完了は、トースト・macOS の通知・表示しない、から選べます。
- **常駐しても邪魔にならない** — メニューバーに常駐し、Dock に起動中の印を残しません。メニューバーのアイコンは、標準の記号とヤモリから選べます。
- **自動でアップデート** — 新しい版が出ると裏でダウンロードし、範囲選択や設定をしていないときに入れ替えます。

<p align="center">
  <img src=".github/assets/settings.png" width="624" alt="設定画面">
</p>

## 動作環境

- macOS 14 Sonoma 以降（Apple Silicon・Intel）
- 外部 CLI で読み取る場合: Codex CLI 0.142.5 以降、または Claude Code 2.1.112 以降

## ダウンロード

[gecko-capture.vercel.app](https://gecko-capture.vercel.app/) からダウンロードしてください。

## 使い方

| したいこと | 操作 |
|---|---|
| 範囲選択を始める | Dock のアイコンを押す ／ ⌥⇧⌘T ／ メニューバーのアイコン →「範囲を選択してコピー」 |
| 範囲を選ぶ | ドラッグします。Esc で中止できます |
| 結果を受け取る | 読み取った文字がクリップボードに入り、トーストなどで知らせます |
| 設定を開く | メニューバーのアイコン →「設定…」 |

ログイン時に起動する設定にした場合は、何も始めずにメニューバーに常駐します。

## 外部 CLI（ChatGPT・Claude）で読み取る

Apple Vision の代わりに、ChatGPT（Codex CLI）や Claude Code CLI で読み取れます。読み取りにはご自身の契約のログインと利用枠を使い、アプリが API キーを保存することはありません。

1. CLI を入れて、端末でログインします（`codex login` または `claude auth login`）。デスクトップアプリへのログインだけでは、CLI は使えません。
2. 設定の「認識方法」で CLI を選び、CLI のパスを確かめます（Homebrew の既定は `/opt/homebrew/bin/codex`、`/opt/homebrew/bin/claude`）。
3. 「選択範囲の画像を〜へ送信」をオンにします。オンにするまで、画像は送りません。
4. 「利用可否を確認」で、ログインと使えるモデルを確かめます。モデルは CLI から取得した一覧から選べます（空欄は CLI の既定）。

**Fast モード**（既定はオフ）は、対応するモデルでだけ選べます。利用枠の消費が増えたり、追加の費用がかかったりすることがあります。Claude の Fast には Claude Code 2.1.205 以降と、対応する Opus・usage credits が必要です。

## プライバシーとセキュリティ

- 選んだ範囲の画像は、作業ごとに作る自分だけが読める一時フォルダに置き、成功・失敗・中止のどの場合も最後に消します。
- Apple Vision を使う場合、画像は Mac の外へ出ません。外部 CLI は、送信を許可したときだけ使います。
- CLI には API キーやトークンなどの環境変数を引き継がず、ツール・MCP・ファイルやコマンドの操作を無効にして呼び出します。アプリが CLI の資格情報を読み取ることはありません。
- 画像の中の文字は読み取る対象として扱い、指示として実行することはありません。
- アップデートの確認では、GitHub の最新のリリースに置いた更新情報を1日1回読みます。新しい版は、署名を確かめてから入れ替えます。設定でオフにできます。
- コピーした文字や通知のプレビューは、macOS やクリップボード履歴のアプリに残ることがあります。

## ライセンスと謝辞

[MIT License](LICENSE) です。

ScreenTextCapture Gecko は、[ku/screentextcapture](https://github.com/ku/screentextcapture)（Copyright © 2019 Kentaro "ku" KUMAGAI、MIT License）をもとに作り直したフォークです。Google Cloud Vision への依存を外し、Apple Vision・外部 CLI での読み取り、常駐、設定画面などを加えました。元の著作権表示は [LICENSE](LICENSE) に残しています。
