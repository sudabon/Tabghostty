# Proposal: Phase 2 — 入力の完成（IME・特殊キー・マウス・選択・クリップボード・スクロールバック）

## Why

Phase 1 の時点で入力できるのは、最低限のキーだけである。日常の利用には、少なくとも次が要る。

- 日本語入力
- Claude Code での Shift+Enter 改行
- JIS キーボードの `¥`
- マウス、選択、コピー＆ペースト、スクロールバック

SPEC.md §7 Phase 2 は、これらを Web 版と同じ挙動にすることを求めている。あわせて、xterm.js では対応していなかった kitty keyboard protocol も、libghostty-vt のキーエンコーダを使うことで対応できる。

## What Changes

- **IME（`NSTextInputClient`）**
  - 未確定の文字列は、カーソル位置に重ねて描く（Terminal には書き込まない）。
  - 送るのは確定した文字列だけにする。
  - 変換候補のウィンドウは、カーソルの位置に出す。
- **特殊キー**（webtabinal `web/src/terminal-input.ts` と同じ条件）
  - Shift+Enter は `ESC CR` にする。`shift_enter_newline` が有効なときだけで、IME で変換中のときは除く。
  - `¥` は `\` にする。修飾キー付き、IME で変換中、ペーストのときは対象外。
- **kitty keyboard protocol と focus reporting**
  - エンコーダを使って、アプリが要求したとおりに報告する。
- **Option キー**
  - Web 版（xterm.js の既定）と同じく、文字合成として扱う。Meta としては扱わない。
- **マウス**
  - アプリがマウス報告を有効にしているときは、マウスエンコーダで送る（SGR と `?1016` のピクセル座標を含む）。
  - Shift を押しながらドラッグすると、マウス報告より選択を優先する。
- **選択とコピー**
  - ドラッグで範囲を、ダブルクリックで単語を、トリプルクリックで行を選択する。
  - Cmd+C で plain テキストとしてコピーする。この操作は PTY には送らない。
  - `copy_on_select` に対応する。
- **ペースト**
  - Cmd+V でテキストを貼り付ける。bracketed paste と改行の正規化を行う。
  - 危険なペーストのときは確認を出す。
  - Ctrl+V はそのまま `0x16` として送る。
- **Edit メニュー**
  - Copy ⌘C と Paste ⌘V を追加する。
- **OSC 52**
  - 書き込みは live のときだけ許可し、`NSPasteboard` に書く。読み取りは常に拒否する。
- **スクロールバック**
  - トラックパッドとホイールで viewport をスクロールする。
  - alternate screen にいて、かつマウス報告が無効なときは、上下キーに変換する（xterm.js と同じ）。
  - キーを入力したら最下部に戻る。

## Capabilities

### New Capabilities

- `terminal-clipboard`
  - 選択、コピー、copy on select、テキストのペースト。
  - 危険なペーストの確認、OSC 52、Edit メニュー。
- `terminal-mouse`
  - マウス報告、選択との使い分け、スクロールバックとホイールの変換。

### Modified Capabilities

Phase 1 の change（`phase1-single-tab-terminal`）を先に archive しておくこと。

- `terminal-input`: IME、Shift+Enter、`¥`、kitty keyboard protocol、focus reporting、Option キーの扱い、キー入力で最下部へ戻る挙動を追加する。

## Impact

- `TerminalUI`
  - `TerminalView` に `NSTextInputClient`、マウスのイベント、選択の描画、スクロールを追加する。
  - Edit メニューを追加する。
- `TerminalCore`
  - マウスエンコーダ、選択、フォーマッタ（plain）、ペーストユーティリティ、viewport スクロールのラッパーを追加する。
- `DaemonClient`
  - config の読み取りに `shift_enter_newline` と `copy_on_select` を追加する。
- テストを移植する: webtabinal `web/tests/terminal-input.test.ts` のうち Shift+Enter と ¥ のケース、`clipboard.test.ts` のうちネイティブにも当てはまるケース。
- webtabinal（デーモン・web）は変更しない。
