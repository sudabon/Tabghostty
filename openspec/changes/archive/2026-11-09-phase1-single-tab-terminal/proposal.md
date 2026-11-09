# Proposal: Phase 1 — 単一タブの表示（デーモン接続・replay・Core Text 描画）

## Why

Phase 0 で libghostty-vt をリンクできるようになった。しかし Tabghostty はまだ webtabinal デーモンにつながらず、何も表示できない。

SPEC.md §7 Phase 1 の完了条件は次の 2 つで、移行全体の成否はここで決まる。

- ブラウザ版で開いているタブを、ネイティブ版でも同時に表示・操作できること。
- 再接続しても、シェルの入力行にゴミが入らないこと。

## What Changes

- **デーモン接続（`DaemonClient`）**
  - `~/Library/Application Support/WebTabinal/config.json` から `port` と `auth_token` を読む。
  - デーモンが動いているかを確認する（`GET /api/config` の 401 応答シグネチャで判定）。止まっていれば、同梱している `webtabinal-daemon serve` を起動する。
  - Bearer 認証で WebSocket に接続し、`sessions` と `state` を受け取る。
  - 切断したら指数バックオフ（0.5〜5 秒）で再接続する。
- **attach / replay / live（`TerminalController`）**
  - SPEC §4.3 の状態遷移（`.detached → .replaying → .live`）を実装する。
  - replay 中は端末応答もユーザー入力も送らない。
  - `attach_overflow` を受けたら reset して attach し直す。
  - 再接続したら attach し直し、サイズを送り直す。
- **VT エンジンの拡張**
  - effect を書き込みの外でキューから処理する。
  - セルのピクセルサイズ付きでリサイズする。
  - スクロールバックの上限を `scrollback_lines` で設定する。
  - デスクトップ通知・タイトル・ベルの effect は無視する。
- **描画（`TerminalView` + Core Text）**
  - 前景色・背景色（デーモンの OSC 10/11/12 と同じ値、ANSI 16 色は現行 xterm.js の既定値）、太字・斜体・下線、全角、絵文字とフォールバックフォント、カーソル（形状と点滅）を描く。
  - フォントは `font_family` / `font_size` から決める。
  - dirty 行だけを再描画する。
- **リサイズ**
  - ビューのサイズから cols / rows を計算する。
  - デバウンスしてから Terminal と PTY（`resize` フレーム）に反映する。
- **最小限のキー入力**
  - `NSEvent` をキーエンコーダで変換し、`input` フレームで送る。
- **アプリの外枠（最小限）**
  - ウィンドウを 1 枚出し、アクティブセッションを表示する。タイトルは `<dir> — Tabghostty`。
  - About / Hide / Quit メニューを置く。
  - 起動に失敗したら、エラーと再試行ボタンを出す。
  - エラーは一時的なメッセージ（トースト）で知らせる。
  - ウィンドウを閉じるとアプリは終了するが、デーモンは残す。
- **アクティブセッションと起動時のセッション確保**
  - アクティブセッションの選び方は Web 版と同じにする（一覧に残っていれば維持、無ければ先頭）。
  - 起動時にセッションが 0 件なら作成する。先頭のセッションが終了済みなら再起動する。
- **`.app` のビルド**
  - `make app` で `build/Tabghostty.app` を作る。
  - webtabinal のデーモン（`bin/webtabinal`）を `Contents/MacOS/webtabinal-daemon` として同梱する。
- **フィクスチャ**
  - webtabinal の `tests/fixtures/agents` をコピーして取り込む。
  - それをエンジンに流す回帰テストを追加する。

## Capabilities

### New Capabilities

- `daemon-connection`
  - config の読み取り、デーモンの検出と起動、認証。
  - WebSocket の接続・keepalive・再接続。
  - セッション一覧の受信。
  - 秘密情報の扱い。
- `terminal-session`
  - セッションごとの attach / replay / live のライフサイクル。
  - replay 中の送信抑止、overflow 時の attach し直し、サイズの同期。
- `terminal-rendering`
  - セルの描画（色・スタイル・全角・フォールバック・カーソル）。
  - フォントの決定、配色、セルの寸法とグリッドの寸法。
- `terminal-input`
  - キー入力を端末に送るときの基本規則。Phase 2 で IME、Shift+Enter、¥ などを追加する。
- `app-shell`
  - アプリのウィンドウ、メニュー、起動失敗画面、一時メッセージ、終了の振る舞い。
- `tab-operations`
  - アクティブセッションの選び方と、起動時のセッション確保。タブ操作（作成・複製・再起動・閉じる・並べ替え）は Phase 3 で追加する。

### Modified Capabilities

Phase 0 の change（`phase0-libghostty-foundation`）を先に archive しておくこと。

- `terminal-engine`: effect の扱い、リサイズ、スクロールバック上限、直列アクセス、フィクスチャの扱いを追加する。
- `build-system`: `.app` バンドルの作成と、デーモンの同梱を追加する。

## Impact

- 新規モジュール: `DaemonClient`、`TerminalUI`、`DesktopSupport`（webtabinal `desktop/Sources/DesktopSupport.swift` から必要な部分を移植）、`Tabghostty`（@main）。
- `TerminalCore` を拡張する。
- 新規スクリプト: `scripts/build-app.sh`、`scripts/sync-fixtures.sh`。
- Makefile に `app` と `fixtures` を追加する。
- ビルド時の依存として webtabinal のチェックアウトが要る。既定は `../webtabinal`。`WEBTABINAL_DIR` で場所を、`WEBTABINAL_DAEMON` でビルド済みバイナリを指定できる。
- webtabinal のデーモンと web は変更しない。プロトコルは既存のものを使う。
- ブラウザ版と同じセッションに同時に attach するため、端末問い合わせには両方のクライアントが応答する。これは現行の挙動のまま許容し、design.md のリスクとして記録する。
