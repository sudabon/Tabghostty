# WebTabinal ネイティブ化 実装指示書（libghostty-vt ベース）

- 対象リポジトリ: `github.com/sudabon/webtabinal`（調査時点のコミット `6dca08f`、2026-11-06）
- 対象ライブラリ: libghostty-vt 1.0（2026-11-06 リリース、C ABI 安定版）
- 想定読者: 実装者本人、または Claude Code などのコーディングエージェント
- 作成日: 2026-11-08

> **Tabghostty での読み替え（2026-11-09 追記）**: この指示書は `webtabinal/native/` を前提に書かれている。Tabghostty では、リポジトリ直下に読み替え、デーモンは webtabinal に残す構成で実装した。ただし、Phase 6 で方針を変え、webtabinal のデーモンを `daemon/` に取り込み、そこからビルドしたものをアプリに同梱している（webtabinal のリポジトリは変更しない。取り込み元は `daemon/UPSTREAM.md`）。

---

## 0. この指示書のゴール

xterm.js + React + WKWebView で構成されている WebTabinal の **描画・入力層を、libghostty-vt を使ったネイティブ macOS アプリに置き換える**。

満たすべき条件は次の 3 つ。

1. **既存の仕様（README に書かれている挙動）を落とさない。** タブ管理、エージェント状態検出、通知、セッション復元、画像添付、キーボード設定などは、ユーザーから見て同じに動くこと。
2. **Go デーモンの資産をそのまま活かす。** PTY 管理、エージェント検出、通知の dedupe、hook 受信、セッション復元はデーモン側にあり、これらは描画方式と無関係なので作り直さない。
3. **段階的に移行できること。** 移行中もブラウザ版 UI（`web/`）は動き続け、ネイティブ版と同じデーモンに同時接続できること。

---

## 1. 現行アーキテクチャの整理

```
┌──────────────────────────── macOS ─────────────────────────────┐
│                                                                │
│  WebTabinal.app (desktop/, Swift)                              │
│   └ WKWebView ── http://127.0.0.1:8642 ──┐                     │
│       React + xterm.js (web/)            │ REST + WebSocket    │
│                                          │ (JSON + base64)     │
│  Browser / PWA ──────────────────────────┤                     │
│                                          ▼                     │
│  webtabinal-daemon (Go, cmd/webtabinal + internal/)            │
│   ├ session/      PTY(creack/pty)・リングバッファ・シェル統合      │
│   ├ osc/          OSC 7/133/9/99/777/9973 解析、OSC10-12 自動応答 │
│   ├ vtscreen/     ヘッドレス画面モデル(charmbracelet/x/vt)        │
│   ├ agentdetect/  画面下端+マニフェストでエージェント状態判定        │
│   ├ notifyarbiter 4秒 first-wins の通知 dedupe                  │
│   ├ restore/      エージェントタブの復元                          │
│   ├ imagedrop/    画像添付の保存                                 │
│   └ server/       REST API・WebSocket Hub・認証                  │
│                                                                │
│  webtabinal notify (CLI) ── Bearer token ──► /api/.../notify   │
└────────────────────────────────────────────────────────────────┘
```

### 1.1 xterm.js が担っている責務（＝置き換え対象）

`web/src/components/TerminalView.tsx` で使われているもの。

| 責務 | 現行実装 |
|---|---|
| VT パース・画面状態・スクロールバック | `@xterm/xterm`（`scrollback: scrollback_lines`） |
| 描画 | `@xterm/addon-webgl`（失敗時 DOM レンダラー） |
| サイズ合わせ | `@xterm/addon-fit` |
| リンク | `@xterm/addon-web-links` → `openExternalLink` |
| 検索 | `@xterm/addon-search` |
| インライン画像 | `@xterm/addon-image`（kitty / Sixel / iTerm2 IIP） |
| キー → バイト列 | xterm.js 内蔵（kitty keyboard protocol は**未対応**） |
| 端末問い合わせへの応答（DA/DSR/CSI 14t 等） | xterm.js が `onData` で返し、`input` フレームで PTY へ |
| 選択・コピー・copy on select | xterm.js の selection API |

### 1.2 React 側が担っている責務（＝AppKit で作り直す対象）

| 機能 | 主なファイル |
|---|---|
| サイドバー（タブ一覧・並べ替え・未読ドット・状態 pill・メモ表示） | `Sidebar.tsx`, `AgentStatePill.tsx`, `@dnd-kit/*` |
| タブ右クリックメニュー（複製・再起動・閉じる・通知トグル） | `TabContextMenu.tsx`, `tab-menu.ts` |
| タブメモ（30 文字まで） | `TabMemoModal.tsx` |
| 設定（一般・外観・キーボード・通知） | `SettingsModal.tsx`, `*Settings.tsx` |
| キー操作（Cmd+N、Cmd+1〜9、Ctrl+J プレフィックスのコード） | `keymap.ts`, `App.tsx` |
| Shift+Enter → `ESC CR`、`¥` → `\` | `terminal-input.ts` |
| クリップボード・画像ペースト/ドロップ | `clipboard.ts`, `image-attach.ts` |
| 通知の発火・フォーカス判定・Dock バッジ | `notify.ts`, `notification-provider.ts` |
| WebSocket 接続・再接続・replay | `ws.ts`, `session-state.ts`, `boot.ts` |
| テーマ（light / dark / system） | `theme.ts`（`internal/osc/color.go` と色を同期） |

### 1.3 デーモン側の重要な仕様（ネイティブクライアントが守るべきもの）

- **認証**: `/api/*` は Cookie `webtabinal_token` または `Authorization: Bearer <auth_token>` が必要。`auth_token` は `~/Library/Application Support/WebTabinal/config.json` にある。`Host` は `127.0.0.1:<port>` か `localhost:<port>` のみ許可。`Origin` を付ける場合も同じ値でなければ 403。
- **OSC 10/11/12（色問い合わせ）はデーモンが自前で応答**し、クライアントが重複して返した応答は `osc.FilterColorReports` で捨てる。つまりクライアント側の libghostty-vt が色応答を返しても実害はない。
- **リングバッファ replay はバイト境界を考慮しない**（README「既知の制約」）。replay 先頭が壊れたシーケンスで始まりうる。
- `close_tab_on_clean_exit`、`notification.commands` による絞り込み、dedupe、hook 受信、復元は**すべてデーモン側**で完結している。

---

## 2. 移植方針

### 2.1 採用案: 「デーモン維持 ＋ ネイティブクライアント差し替え」

```
┌──────────────────────────── macOS ─────────────────────────────┐
│  WebTabinal.app (native/, Swift + AppKit)                      │
│   ├ SessionStore      REST + WebSocket クライアント              │
│   ├ TerminalController (タブごと)                                │
│   │    └ libghostty-vt: Terminal + RenderState + Key/Mouse Enc │
│   ├ TerminalView      NSView + NSTextInputClient (IME)          │
│   │    └ Renderer      Phase1: Core Text / Phase5: Metal        │
│   ├ SidebarView, SettingsWindow, MemoSheet …                    │
│   └ NativeNotificationService（既存 DesktopSupport.swift を流用）  │
│              │ REST + WebSocket（既存プロトコルのまま）            │
│              ▼                                                  │
│  webtabinal-daemon (Go) ── 変更なし（Phase 6 で任意に強化）        │
└────────────────────────────────────────────────────────────────┘
```

理由:

- WebTabinal の価値の大半（エージェント検出、通知、復元、hook）はデーモンにある。ここは描画方式に依存しない。
- 「ウィンドウを閉じてもセッションが残る」「ブラウザからも同じセッションを見られる」という現行の運用をそのまま維持できる。
- xterm.js が担っていた「VT 状態管理」を libghostty-vt に、「描画」を自前レンダラーに置き換えるだけなので、責務の境界が明確。
- 既存の `desktop/` が既に Swift で、通知・クリップボード・デーモン起動のコードがある。流用できる。

### 2.2 検討して採用しなかった案

| 案 | 採用しない理由 |
|---|---|
| PTY もアプリ内で持つ一体型アプリ | ウィンドウを閉じるとセッションが消える。`webtabinal notify` の受け口、エージェント検出、復元をすべて作り直すことになる |
| Go でネイティブ GUI（go-libghostty + Go GUI ライブラリ） | macOS の IME・通知・メニュー・Dock 連携は Swift/AppKit が圧倒的に楽。Go 側は libghostty の Go バインディングも API 未安定 |
| `ghostty-web`（WASM、xterm.js 互換 API）に差し替えるだけ | 最小コストでエミュレーション精度は上がるが、「ブラウザではないアプリ」という目的を満たさない。**ただし Phase 0 の比較検証用としては有用**（後述） |

### 2.3 実装言語・主要技術

| 項目 | 選定 | 備考 |
|---|---|---|
| 言語 | Swift 6 | 既存 `desktop/` に合わせる |
| UI | AppKit（必要に応じて SwiftUI を部分利用） | ターミナル本体は `NSView` 直書き。IME のため `NSTextInputClient` が必須 |
| VT エンジン | libghostty-vt 1.0（公式 XCFramework） | macOS 13+ をサポート |
| 描画 | Phase 1: Core Text / Core Graphics、Phase 5: Metal | 先に正しさ、後で速度 |
| 通信 | `URLSessionWebSocketTask` + `URLSession` | 外部依存なし |
| ビルド | SwiftPM（`native/Package.swift`）+ 既存の `build-app.sh` を拡張 | Xcode プロジェクトは作らない方針でもよい |
| 最小 OS | **要決定**。推奨は macOS 14（`NSView.displayLink` が使えるため） | libghostty 自体は 13+ |

---

## 3. libghostty-vt の使い方（本プロジェクトで使う範囲）

> **重要**: C 関数名・型名は `include/ghostty/vt.h` と `include/ghostty/vt/*.h` を**正**とすること。本書では概念を Go バインディング（`go.mitchellh.com/libghostty`）の名前で示す。Go 名は C API を薄くラップしたものなので、ヘッダ内で対応する関数を探す手がかりになる。実装前に、配布物の `examples/` と生成ドキュメントを必ず読むこと。

### 3.1 提供されるもの / 自前で用意するもの

| libghostty-vt が提供 | 本アプリが自前で実装 |
|---|---|
| VT パース、画面・スクロールバック状態、リフロー付きリサイズ | PTY（＝デーモンが担当済み） |
| 増分描画用の Render State（行・セル・スタイル・色・カーソル・dirty 管理） | フォントのラスタライズ、グリフアトラス、描画 |
| キーエンコーダ（kitty keyboard protocol 対応）、マウスエンコーダ、フォーカスエンコード | `NSEvent` → ライブラリのキーイベント構造体への変換 |
| ペースト用ユーティリティ（bracketed paste、危険なペーストの検査） | クリップボード読み書き |
| 選択、検索、OSC/SGR パーサ、フォーマッタ（plain / VT / HTML） | 選択のマウス操作 UI、検索 UI |
| Kitty Graphics の画像・配置の取得 | 画像の描画 |
| Terminal Snapshot（状態のエンコード・増分復元） | — |
| effect コールバック（PTY への書き戻し、ベル、タイトル変更、クリップボード、デスクトップ通知、セマンティックプロンプトなど） | 各 effect への対応 |

### 3.2 オブジェクトの持ち方

タブ（セッション）1 つにつき、次を 1 組持つ。

```
TerminalController (actor もしくは専用 serial queue に閉じ込める)
 ├ terminal     : Terminal        … size, max scrollback, effects を設定して生成
 ├ renderState  : RenderState     … 描画用スナップショット
 ├ keyEncoder   : KeyEncoder
 ├ mouseEncoder : MouseEncoder
 └ phase        : .detached | .replaying | .live
```

制約（Go バインディングのドキュメントに明記されているもの。C API でも同じ前提で扱う）:

- **ハンドルはスレッドセーフではない。** 1 つのキュー/actor に閉じ込める。
- **effect コールバックは書き込み処理（VT write）の中で同期的に呼ばれ、その中から同じ Terminal に書き込んではならない。** コールバックではキューに積むだけにして、外で処理する。
- **Render State の更新中は Terminal を排他的に保持する。** 取得したビューは次の変更操作までしか有効でない。

### 3.3 Terminal 生成時の設定

| 設定 | 値の出所 |
|---|---|
| サイズ（cols, rows） | ビューのピクセルサイズ ÷ セルサイズ |
| 最大スクロールバック行数 | `config.scrollback_lines`（既定 10000） |
| セルのピクセルサイズ | リサイズ時に渡す（CSI 14t などのサイズ報告と画像スケールに使われる）。Retina では**物理ピクセル**で渡すこと（現行 README の「CSS ピクセルを返してスケールがずれる」問題がここで解消できる） |

### 3.4 effect の扱い

| effect | 本アプリでの扱い |
|---|---|
| PTY への書き戻し（DA/DSR/サイズ報告/kitty の応答など） | `phase == .live` のときだけ WebSocket の `input` フレームで送る。**`.replaying` 中は必ず破棄**（後述 4.3） |
| ベル | Dock バウンス、またはタブの未読扱い。**要決定**（現行 Web 版の挙動に合わせるなら無視でも可） |
| タイトル変更 | タブ名表示には使わない（タブはデーモンの `cwd`/`command` で表示している）。ウィンドウタイトルへの反映は任意 |
| クリップボード書き込み（OSC 52） | 許可して `NSPasteboard` に書く |
| クリップボード読み取り（OSC 52 read） | **既定で拒否**（安全側）。設定項目化は将来課題 |
| デスクトップ通知（OSC 9/99/777） | **無視する。** デーモンが同じバイト列を解析して dedupe 付きで `notify` フレームを送ってくるため、ここで出すと二重通知になる |
| 進捗報告（OSC 9;4） | 無視（デーモンも待ち通知扱いしていない）。将来タブに進捗バーを出すなら利用 |
| セマンティックプロンプト（OSC 133） | 任意。「前/次のプロンプトへジャンプ」機能を付けるなら利用 |

---

## 4. デーモンとの接続仕様（ネイティブクライアント側）

### 4.1 起動と認証

1. `config.json` から `port` と `auth_token` を読む（既存 `DesktopSupport.swift` の `configuredPort` を流用し、token 読み取りを追加）。
2. 既存の `webTabinalListening(port:)` でデーモン稼働を確認し、未起動なら既存の `spawnDetachedDaemon()` で起動する。ここは現行 `desktop/` のロジックをそのまま移す。
3. すべてのリクエストに `Authorization: Bearer <auth_token>` を付ける。`Host` は `127.0.0.1:<port>`。`Origin` ヘッダは付けない。
4. WebSocket は `ws://127.0.0.1:<port>/api/ws`。アップグレード要求にも同じ Bearer ヘッダを付ける。

### 4.2 WebSocket フレーム（既存プロトコル、変更しない）

クライアント → デーモン:

| `t` | フィールド | 用途 |
|---|---|---|
| `attach` | `sid` | セッションの出力購読を開始。リングバッファの replay が始まる |
| `input` | `sid`, `data`(base64) | キー入力・ペースト・端末応答 |
| `resize` | `sid`, `cols`, `rows` | 1〜10000 の範囲外は無視される |

デーモン → クライアント（`web/src/types.ts` の `ServerMsg` と同じ）:

| `t` | 主なフィールド | 処理 |
|---|---|---|
| `sessions` | `list: SessionInfo[]` | 接続直後と一覧変化時。タブ一覧を丸ごと置換 |
| `state` | `sid, cwd, cmd, state, exit, integrated, run_ms` | タブの表示更新 |
| `agent_state` | `sid, agent, agent_state, agent_state_since, agent_state_signal, agent_state_detail` | 状態 pill の更新 |
| `notify` | `sid, title, body, kind, source` | 通知の発火判定へ（4.5） |
| `replay` | `sid, data, done` | Terminal に流す。`done: true` で live へ移行 |
| `output` | `sid, data` | Terminal に流す |
| `error` | `sid, code, message` | `code == "attach_overflow"` なら再 attach |

`SessionInfo` の各フィールドは `internal/session/session.go` の `Info` 構造体を正とする（`shell_exited`, `prompt_seen` など TS 型に無いフィールドもある）。Swift 側は `Codable` で、未知フィールドを無視する作りにする。

### 4.3 attach / replay のルール（最重要）

```
attach 送信
  └ phase = .replaying, Terminal を reset
replay フレーム受信 → Terminal に書く（PTY 書き戻し effect は破棄）
replay done=true
  └ phase = .live, 自ビューのサイズで resize を送り直す
output フレーム受信 → Terminal に書く（PTY 書き戻し effect は input で送る）
error attach_overflow → もう一度 attach（Terminal を reset してやり直し）
```

- **replay 中に端末応答を送ってはいけない。** replay には過去の DA/DSR 問い合わせも含まれる。これに応答すると、シェルの入力行にゴミが流れ込む。現行 Web 版は `shouldForwardTerminalInput(sid, replaying)` で同じことをしている。
- replay 中のユーザーのキー入力も送らない（現行と同じ）。
- タブ切り替えで attach をやめる必要はない。**全タブを attach したままにして、裏のタブも Terminal を更新し続ける**方が切り替えが速く、未読判定とも整合する。ただしメモリ使用量は増えるので、タブ数上限の想定（例: 30 タブ × scrollback 10000 行）で計測すること。
- 複数のクライアント（ブラウザ版とネイティブ版など）が同じセッションに attach していると、端末問い合わせに両方が応答する。これは現行（ブラウザ 2 窓）でも同じ挙動なので Phase 1〜4 では許容し、リスクとして記録する（9 章）。

### 4.4 REST API（使うもの）

`internal/server/server.go` のルーティングと同じ。

| メソッド・パス | 用途 |
|---|---|
| `GET /api/sessions` | 一覧（WS の `sessions` と同内容。起動時のフォールバック用） |
| `POST /api/sessions` | 新規タブ（Cmd+N） |
| `POST /api/sessions/{id}/duplicate` | 複製 |
| `POST /api/sessions/{id}/restart` | 再起動 |
| `PATCH /api/sessions/{id}` | メモ・通知ミュートの変更 |
| `DELETE /api/sessions/{id}` | 閉じる |
| `PUT /api/sessions/order` | 並べ替え |
| `POST /api/sessions/{id}/images` | 画像添付（レスポンスの `path` をペースト） |
| `GET /api/config` / `PATCH /api/config` | 設定の取得・変更 |

リクエスト・レスポンスの正確な形は `web/src/api.ts` と `internal/server/api.go` を読んで合わせること。

### 4.5 通知の発火判定

現行の判定ロジックは `web/src/notify.ts` と `notification-provider.ts` にある。これを Swift に移植する（判定はクライアント側、dedupe と絞り込みはデーモン側、という分担は変えない）。

- `notification.enabled` が false なら出さない。
- タブがアクティブかつウィンドウがフォーカス中で、`notification.always` が false なら出さない。
- `notifications_muted` のタブは出さない（未読ドットと Dock バッジは付ける）。
- 通知クリックでそのタブをアクティブにする（既存の `NotificationActivationCoordinator` を流用）。
- 表示は既存の `NativeNotificationService` をそのまま使う。

---

## 5. 機能マッピング（xterm.js / React → ネイティブ）

### 5.1 ターミナル本体

| 現行 | ネイティブでの実装 | Phase |
|---|---|---|
| fit addon | セルサイズ = フォントの advance（`M` の幅）× (ascent + descent + leading)。`NSView` のサイズ変更で cols/rows を再計算し、50ms 程度デバウンスして Terminal の resize と `resize` フレーム送信 | 1 |
| WebGL / DOM レンダラー | Phase 1 は Core Text で dirty 行だけ再描画、Phase 5 で Metal | 1 / 5 |
| フォント | `config.font_family` は CSS のフォントスタック文字列（例 `Menlo, Monaco, 'Courier New', monospace`）。カンマで分割し引用符を外して、インストール済みの最初のフォントを使う。`monospace` は `NSFont.monospacedSystemFont` に対応させる。太字・斜体はフォントの trait で派生 | 1 |
| CJK・絵文字 | 全角は 2 セル幅（幅情報は libghostty-vt のセルから取る）。フォールバックは `CTFontCreateForString` | 1 |
| カーソル（blink 含む） | Render State のカーソル位置・表示/点滅・形状を使う。点滅は 530ms 程度のタイマー | 1 |
| テーマ | `web/src/theme.ts` の配色を Swift に移植。**`internal/osc/color.go` の Palette と値を一致させる**（デーモンが OSC 10/11/12 に返す値と画面の色がずれないように） | 1 |
| キー入力 | `NSEvent` → キーエンコーダ → `input` フレーム。kitty keyboard protocol は libghostty-vt が処理するので、現行で未対応だったものが自然に対応になる | 2 |
| IME（日本語入力） | `NSTextInputClient` を実装。未確定文字列はカーソル位置にオーバーレイ描画（Terminal には書かない）。確定時だけ `input` で送る。`firstRect(forCharacterRange:)` で変換候補ウィンドウの位置をカーソルに合わせる | 2 |
| Shift+Enter → `ESC CR` | `shift_enter_newline` が true のとき、キーエンコーダより前で横取りして `\x1b\r` を送る。IME 変換中の Enter は除外（`terminal-input.ts` と同じ条件） | 2 |
| `¥` → `\` | JIS キーボードの `¥` 単独押下を `\` に置き換える。修飾キー付き・IME 中・ペーストは対象外（同上） | 2 |
| マウス | マウスエンコーダでセル座標（可能ならピクセル座標 `?1016`）を送る。マウスモード無効時はドラッグで選択 | 2 |
| 選択・コピー | ライブラリの選択機能で範囲を管理し、フォーマッタ（plain）で文字列化して `NSPasteboard` へ。ダブルクリックで単語、トリプルクリックで行 | 2 |
| copy on select | `copy_on_select` が true なら選択確定時にコピー | 2 |
| ペースト | Cmd+V。ペーストユーティリティで bracketed paste 化と危険ペースト検査。クリップボードが画像なら画像添付（下記） | 2 |
| Ctrl+V 素通し | Codex / Claude Code が自前でクリップボードを読む経路なので、そのまま `\x16` を送る | 2 |
| スクロールバック | トラックパッドのスクロール → viewport スクロール。alternate screen 中でマウスモード無効なら上下キーに変換（ターミナルの一般的な挙動。**要決定**） | 2 |
| web-links | OSC 8 ハイパーリンクはセル属性から取得。素の URL は表示行テキストに正規表現をかけて検出。Cmd+クリックで `NSWorkspace.open` | 5 |
| 検索 | ライブラリの検索機能 + Cmd+F の検索バー | 5 |
| インライン画像 | Kitty Graphics のみ対応。画像と配置をライブラリから取り、テクスチャとして描画。**Sixel / iTerm2 IIP は対応外になる見込み**（9 章） | 5 |

### 5.2 アプリの外枠

| 現行 | ネイティブでの実装 | Phase |
|---|---|---|
| サイドバー | `NSSplitView` + `NSTableView`（または `NSOutlineView`）。行に cwd/コマンド/メモ/未読ドット/状態 pill。幅は `sidebar_width`、折りたたみ可 | 3 |
| ドラッグ並べ替え | `NSTableView` のドラッグ & ドロップ → `PUT /api/sessions/order`。**自動ソートはしない**（README の仕様） | 3 |
| 状態 pill | `agent_state` が `idle` / `working` / `blocked` のときのみ表示。`none` は非表示。`state.enabled` が false なら非表示 | 3 |
| 未読ドット・Dock バッジ | 非アクティブタブの出力、または通知対象イベントで未読。バッジ数 = 未読タブ数（`NSApp.dockTile.badgeLabel`）。現行の未読条件は `App.tsx` と `session-state.ts` を読んで合わせる | 3 |
| 右クリックメニュー | 複製・再起動・閉じる・「通知」チェック（`notifications_muted` のトグル） | 3 |
| メモ | シート（`NSAlert` + テキストフィールドで可）。30 文字（rune）上限はデーモンでも検証される | 3 |
| Cmd+N / Cmd+1〜9 | メインメニューのキー等価で実装 | 3 |
| コード（Ctrl+J のあと n / p / j） | `key_bindings` の設定で動作。`keymap.ts` の正規化・予約キー・3 秒タイムアウトを移植。**ターミナルへのキー送信より前に判定する** | 3 |
| 閉じる前の確認 | `confirm_close_running` が true で `state == running` のタブを閉じるときに確認ダイアログ | 3 |
| 最後のタブで終了 | `quit_when_no_tabs` が true なら、タブが 0 になったらアプリ終了（デーモンは残す） | 3 |
| 設定画面 | `NSWindow` に 4 タブ（一般・外観・キーボード・通知）。`GET/PATCH /api/config`。項目は既存の `*Settings.tsx` を一つずつ移す | 4 |
| 通知 | 4.5 のとおり。既存 Swift コードを流用 | 4 |
| 画像添付（ペースト・ドロップ） | `NSPasteboard` の画像 → PNG 化 → `POST /api/sessions/{id}/images` → 返ってきた `path` をバックスラッシュエスケープしてペースト。ドロップ時は点線のドロップ枠を表示。複数枚はスペース区切り、失敗分は飛ばす。**アップロード中にタブを切り替えたら貼らない**（`TerminalView.tsx` と同じ） | 4 |
| カラースキーム | `color_scheme` が `system` なら `NSApp.effectiveAppearance` を監視 | 4 |
| PWA / ブラウザ版 | 変更しない。並行して使える状態を保つ | — |

---

## 6. ディレクトリ構成

```
webtabinal/
├ cmd/, internal/        … 変更しない（Phase 6 のみ internal/vtscreen に追加）
├ web/                   … 変更しない
├ desktop/               … 移行完了まで残す（Phase 7 で削除または native/ に統合）
└ native/                … 新規
   ├ Package.swift
   ├ Vendor/
   │  └ GhosttyVt.xcframework   … libghostty-vt 1.0 公式 XCFramework（git 管理外、取得スクリプトで配置）
   ├ Sources/
   │  ├ WebTabinal/             … @main、AppDelegate、メニュー、ウィンドウ
   │  ├ DaemonClient/           … config 読み込み、デーモン起動、REST、WebSocket、Codable モデル
   │  ├ TerminalCore/           … libghostty-vt の Swift ラッパー、TerminalController
   │  ├ TerminalUI/             … TerminalView(NSView)、IME、選択、Renderer
   │  ├ Shell/                  … サイドバー、設定、メモ、通知、キーマップ
   │  └ DesktopSupport/         … 既存 desktop/Sources/DesktopSupport.swift を移設
   ├ Tests/
   │  ├ DaemonClientTests/
   │  ├ TerminalCoreTests/      … フィクスチャ replay テスト（8 章）
   │  └ ShellTests/             … keymap・terminal-input の移植テスト
   └ scripts/
      ├ fetch-libghostty.sh     … リリース tarball の取得・署名検証・XCFramework 配置
      └ build-app.sh            … .app バンドル作成（デーモンを sidecar として同梱）
```

Makefile に追加するターゲット:

```make
native-deps:   ## libghostty-vt の取得とビルド
	bash native/scripts/fetch-libghostty.sh
native:        build native-deps  ## デーモン + ネイティブ .app
	cd native && swift build -c release
	bash native/scripts/build-app.sh
native-test:
	cd native && swift test
```

`.app` の中身は現行と同じく `Contents/MacOS/` にネイティブ UI 本体と `webtabinal-daemon` を同梱し、UI がデーモンを起動する。`web/` のビルド成果物もデーモンに埋め込まれたままなので、ブラウザ版も引き続き使える。

---

## 7. フェーズ計画と完了条件

各フェーズは「完了条件」をすべて満たしてから次へ進む。

### Phase 0: 準備と検証（目安 1〜2 日）

作業:
1. libghostty-vt 1.0 のリリース tarball を取得し、`PACKAGING-LIBGHOSTTY.md` の手順でビルド（Zig が必要。必要バージョンはドキュメントを確認）。
2. XCFramework を `native/Vendor/` に配置し、SwiftPM の `binaryTarget` として読み込む。
3. Swift から Terminal を生成し、`"Hello\r\n\x1b[31mRed\x1b[0m"` を書き込み、フォーマッタ（plain）で `Hello\nRed` が得られることを確認するテストを書く。
4. （任意）`web/` で xterm.js を `ghostty-web` に差し替えたブランチを作り、Claude Code / Codex / cursor-agent / vim / htop の表示を xterm.js と見比べる。libghostty の挙動を事前に把握するための使い捨て検証。

完了条件:
- [ ] `swift test` で上記テストが通る
- [ ] C ヘッダを読み、本書 3 章の各概念に対応する C 関数名の一覧を `native/Sources/TerminalCore/README.md` に書き出してある

### Phase 1: 単一タブの表示（目安 3〜5 日）

作業:
1. `DaemonClient`: config 読み込み、デーモン起動確認、WebSocket 接続、`sessions` 受信。
2. 最初のセッションに `attach` し、replay → live の流れを実装（4.3）。
3. `TerminalView` に Core Text で描画（背景色、前景色、太字/斜体、下線、全角、カーソル）。
4. リサイズ（ビューのサイズ → cols/rows → Terminal resize + `resize` フレーム）。
5. 最低限のキー入力（キーエンコーダ経由）。

完了条件:
- [ ] ブラウザ版で開いているタブを、ネイティブ版でも同時に表示・操作できる
- [ ] `ls --color`、`vim`、`htop`、`claude` が崩れずに表示される
- [ ] ウィンドウサイズを変えると、シェルと TUI が追従する（`stty size` で確認）
- [ ] 再接続（デーモン再起動 → 自動再接続）で画面が復元され、**シェルの入力行にゴミが入らない**

### Phase 2: 入力の完成（目安 4〜6 日）

作業: 5.1 の Phase 2 の行をすべて実装（IME、Shift+Enter、¥、マウス、選択、コピー、ペースト、スクロールバック）。

完了条件:
- [ ] 日本語入力で、変換候補ウィンドウがカーソル位置に出て、確定文字だけがシェルに届く
- [ ] Claude Code で Shift+Enter が改行になり、Enter が送信になる
- [ ] JIS キーボードの `¥` で `\` が入力される
- [ ] `vim` でマウスクリックによるカーソル移動ができる（`:set mouse=a`）
- [ ] 複数行テキストのペーストが bracketed paste として届く（`cat -v` で `ESC[200~` を確認）
- [ ] kitty keyboard protocol を使うアプリ（例: `kitten show-key -m kitty`、または対応 TUI）でキーが正しく判別される

### Phase 3: タブ・サイドバー・状態表示（目安 4〜6 日）

作業: 5.2 の Phase 3 の行をすべて実装。全タブ attach（4.3）。

完了条件:
- [ ] ブラウザ版とネイティブ版で、タブの並び・メモ・通知ミュートが相互に即時反映される
- [ ] Claude Code の作業中/承認待ち/待機中が pill に出る（`tests/fixtures/agents` の状況を実機で再現して確認）
- [ ] 非アクティブタブの出力で未読ドットが付き、Dock バッジ数が合う
- [ ] Cmd+1〜9、Cmd+N、コード操作が動き、ターミナルにキーが漏れない

### Phase 4: 通知・設定・画像添付（目安 3〜5 日）

作業: 5.2 の Phase 4 の行をすべて実装。

完了条件:
- [ ] `scripts/osc9-notification-probe.sh` を実行して macOS 通知が出る
- [ ] `webtabinal notify` 経由のターン完了通知が出て、クリックで該当タブに移動する
- [ ] README の通知トラブルシュート表の各状況で、現行と同じ結果になる（特にフォーカス抑制・ミュート・`notification.commands` の絞り込み）
- [ ] 画像のペーストとドロップで、Claude Code にパスが入力される
- [ ] 設定画面の全項目が `PATCH /api/config` で保存され、ブラウザ版に反映される

**この時点でネイティブ版は現行 `.app` の機能を満たす。** ここで一度、日常利用に切り替えて 1 週間程度使い込むこと。

### Phase 5: 品質と性能（目安 5〜10 日）

作業:
1. Metal レンダラー（グリフアトラス、背景パス + グリフパス、dirty 行のみ更新、`NSView.displayLink` で vsync 同期、dirty が無いフレームは描画しない）。
2. 検索（Cmd+F）、ハイパーリンク（OSC 8 + URL 検出）。
3. Kitty Graphics の描画。
4. （任意・デーモン変更あり）WebSocket の `output` / `replay` を**バイナリフレーム**でも送れるようにする。base64 + JSON のオーバーヘッドを無くす。互換性のため、クライアントが attach 時に `binary: true` を宣言した場合のみ有効にする。

完了条件:
- [ ] `cat` で 50MB のテキストを流しても UI が固まらない（入力が 100ms 以内に反映される）
- [ ] 待機中の CPU 使用率がほぼ 0%（カーソル点滅のみ）
- [ ] タブ 30 枚・各 scrollback 10000 行でのメモリ使用量を計測し、記録してある

### Phase 6（任意）: デーモン側エミュレータの libghostty-vt 化

目的: サーバー側の画面モデル（エージェント検出の入力）とクライアント表示を同じエンジンにして、検出のずれを無くす。

> **2026-11-09 の変更**: webtabinal は変更しないことにした。そのため、デーモンを Tabghostty の `daemon/` に取り込み、以下の作業はその中で行う。Tabghostty.app に同梱するデーモンは `daemon/` から `ghostty` タグでビルドする。この節の図と表にある「webtabinal は変更しない」「Phase 6 で `internal/vtscreen` に追加」は、`daemon/` に読み替える。経緯と詳細は `openspec/changes/phase6-daemon-ghostty-screen` と `daemon/UPSTREAM.md` にある。

作業:
1. `internal/vtscreen/` に `ghostty.go` を追加し、`Screen` インタフェース（`Feed` / `Resize` / `Snapshot` / `Close`）を `go.mitchellh.com/libghostty` で実装する。
   - Terminal 生成は size 指定 + スクロールバック最小。
   - PTY 書き戻し effect は**何もしない**関数を渡す（現行 `drainEmulatorReplies` の役割。応答を返すのはクライアントの仕事）。
   - `Snapshot` の primary / alternate の扱いは、現行 `adapter.go` が `splitAltTransitions` で切り替え時に各バッファをキャプチャしている方式に合わせる。
   - ハンドルは goroutine セーフではないので、既存どおり mutex で守る。
2. **ビルドタグ `ghostty` で切り替える**（`//go:build ghostty`）。既定ビルドは純 Go（charmbracelet/x/vt）のまま。cgo と Zig 製ライブラリへの依存を既定に持ち込まないため。
3. 受け入れ基準は既存テストそのもの: `go test -race -tags ghostty ./internal/vtscreen/... ./internal/agentdetect/... ./internal/session/...` が通ること（`conformance.go`、`contract_test.go`、`fixtures_test.go` がある）。
4. さらに進めるなら、attach 時の replay をリングバッファの生バイトではなく **Terminal Snapshot** で送る方式を検討する。README の既知の制約「replay がシーケンスの途中から始まる」が根本的に解消する。ただしブラウザ版（xterm.js）は Snapshot を読めないため、ネイティブ版専用のフレームとして追加する形になる。

注意: Go バインディングは作者が「API 安定性は約束しない」と明記している。go.mod でコミットを固定し、更新時はテストを必ず通すこと。

### Phase 7: 置き換え

- [ ] `make desktop` をネイティブ版に向け、`desktop/`（WKWebView 版）を削除する
- [ ] README の「インストール」「クイックスタート」「デスクトップアプリの更新」「画像プロトコル」「既知の制約」を更新する
- [ ] 必要ツールに Zig を追加する（libghostty-vt を自前ビルドする場合）

---

## 8. テスト計画

### 8.1 自動テスト

| 対象 | 方法 |
|---|---|
| WebSocket プロトコル | ローカルにモック WS サーバーを立て、`sessions` → `attach` → `replay`(分割) → `output` → `attach_overflow` → 再 attach のシーケンスを再生し、`TerminalController` の phase 遷移と送信フレームを検証 |
| replay 中の応答抑止 | replay データに `ESC[c`（DA1）と `ESC[6n`（DSR）を含め、`input` フレームが**送られない**こと、live 移行後の同じ問い合わせには送られることを検証 |
| フィクスチャ replay | `tests/fixtures/agents/**/stream.raw` を Terminal に流し、フォーマッタ（plain）の出力の下端行を、Go 側 `vtscreen` のスナップショットと比較する（両エンジンの表示一致の確認。Phase 6 の前提検証にもなる） |
| キーマップ | `web/tests/keymap.test.ts` のケースを Swift に移植 |
| Shift+Enter・¥ | `web/tests/terminal-input.test.ts` のケースを Swift に移植 |
| 通知判定 | `web/tests/notify.test.ts`、`notification-provider.test.ts` のケースを移植 |
| 画像添付のパス整形 | `web/tests/image-attach.test.ts` のケースを移植 |

### 8.2 手動テスト

- `vttest` の主要項目
- Claude Code / Codex / cursor-agent の通常ターン、承認待ち、バックグラウンド実行
- `ssh` 先のシェル（README「ssh でログイン中のステータス」の挙動が変わらないこと）
- 日本語・絵文字・結合文字の表示と削除（`echo 'が'`、`echo '👨‍👩‍👧'`）
- 外部モニタと Retina の行き来（セルサイズとフォントの再計算）
- スリープ復帰後の再接続

---

## 9. リスクと未確定事項

| 項目 | 内容 | 対応 |
|---|---|---|
| Sixel / iTerm2 IIP | Ghostty 本体は Sixel に対応しておらず、libghostty-vt でも提供されない見込み。現行 README は Sixel / IIP 対応を謳っている | Phase 0 でヘッダを確認し、無ければ README の対応表から外す。必要なら Kitty Graphics への移行を案内 |
| C API の正確な名前 | 本書では Go 名で記述している | Phase 0 の完了条件で対応表を作る |
| 複数クライアントの重複応答 | 同じセッションに複数クライアントが attach していると、端末問い合わせに両方が応答する（現行でも同じ） | 当面は許容。根本対応はデーモンで「応答は最後に入力したクライアントのものだけ通す」などの調停を入れる（別タスク） |
| IME の作り込み | `NSTextInputClient` は実装量が多く、細かいバグが出やすい | Phase 2 に余裕を持たせる。iTerm2 / Ghostty 本体の実装を参考にする |
| WebSocket の帯域 | JSON + base64 は大量出力に弱い（README の既知の制約） | Phase 5 のバイナリフレーム化で改善 |
| ビルド依存 | libghostty-vt を自前ビルドする場合は Zig が必要 | 公式配布の XCFramework が使えるならそれを使い、Zig は不要にする |
| Go バインディングの API 変動 | Phase 6 のみ影響 | コミット固定 + ビルドタグで既定ビルドから隔離 |
| ベル・alternate screen 中のスクロール | 現行 Web 版での挙動が仕様化されていない | Phase 2 着手前に決める |
| 最小 macOS バージョン | 13 か 14 か | Phase 0 で決める（推奨 14） |

---

## 10. エージェントに作業させる場合のルール

Claude Code などに実装させる場合、次をプロンプトか `CLAUDE.md` に入れること。

1. **Phase 1〜5 ではデーモン（`cmd/`, `internal/`）と `web/` を変更しない。** プロトコルの変更が必要だと判断したら、作業を止めて相談する。
2. 各フェーズの完了条件をチェックリストとして扱い、満たしたものだけにチェックを入れる。手動確認が必要な項目は「要手動確認」と明記して残す。
3. libghostty-vt の関数を使う前に、必ずヘッダの該当箇所を読む。推測で関数名を書かない。
4. effect コールバックの中から Terminal に書き込まない。コールバックではキューに積むだけにする。
5. replay 中に `input` フレームを送るコードを書かない（4.3）。テストで保証する。
6. 既存の Swift コード（`desktop/Sources/DesktopSupport.swift`）は、まずそのまま移設してテストを通し、その後に必要な変更を加える。
7. `config.json` の `auth_token` をログやエラーメッセージに出さない。

---

## 付録 A. 参照すべき既存ファイル

| 知りたいこと | ファイル |
|---|---|
| WS プロトコルと attach/replay | `internal/server/ws.go`, `web/src/ws.ts`, `web/src/types.ts` |
| REST API | `internal/server/server.go`, `internal/server/api.go`, `web/src/api.ts` |
| 認証 | `internal/server/server.go`（`withSecurity`, `validToken`）, `cmd/webtabinal/client.go` |
| 設定項目と既定値 | `internal/config/config.go`, README「デフォルト値」 |
| 端末の初期化オプション | `web/src/components/TerminalView.tsx`, `web/src/theme.ts` |
| キー処理 | `web/src/keymap.ts`, `web/src/terminal-input.ts`, `web/src/clipboard.ts` |
| 通知判定 | `web/src/notify.ts`, `web/src/notification-provider.ts` |
| 画像添付 | `web/src/image-attach.ts`, `internal/imagedrop/` |
| 色の同期 | `web/src/theme.ts` ⇔ `internal/osc/color.go` |
| 画面モデルの抽象 | `internal/vtscreen/screen.go`, `adapter.go`, `conformance.go` |
| 既存ネイティブ部分 | `desktop/Sources/main.swift`, `desktop/Sources/DesktopSupport.swift` |

## 付録 B. 外部資料

- Libghostty 1.0 発表記事: https://mitchellh.com/writing/libghostty-1-0
- libghostty ドキュメント・ダウンロード: https://lib.ghostty.org/
- C ヘッダ: https://github.com/ghostty-org/ghostty/blob/main/include/ghostty/vt.h
- パッケージング手順: https://github.com/ghostty-org/ghostty/blob/main/PACKAGING-LIBGHOSTTY.md
- 最小実装例 Ghostling（約 1,500 行の C、Raylib 使用）: https://github.com/ghostty-org/ghostling
- Go バインディング: https://pkg.go.dev/go.mitchellh.com/libghostty
- WASM 版（xterm.js 互換 API）: https://github.com/coder/ghostty-web
- 採用事例一覧: https://github.com/Uzaaft/awesome-libghostty
