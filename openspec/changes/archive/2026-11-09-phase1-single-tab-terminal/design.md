# Design: Phase 1 — 単一タブの表示

## Context

- 前提は Phase 0 の成果物: SwiftPM パッケージ、`TerminalCore` の最小ラッパー、C API 対応表（`Sources/TerminalCore/README.md`）。libghostty-vt の関数は、この表にある名前だけを使う。
- 接続先は webtabinal デーモン。プロトコルは変更しない。2026-11-09 時点の webtabinal `6dca08f` を読んで、次の事実を確認した。
  - **プローブ**: トークン無しで `GET /api/config` を送ると、`401`、本文 `unauthorized\n`、`X-Frame-Options: DENY`、`nosniff`、CSP が返る。webtabinal の `isWebTabinalProbeResponse` がこの組み合わせで判定している。
  - **認証**:
    - `/api*` は Cookie か `Authorization: Bearer` のどちらかが必須。
    - `Host` は `127.0.0.1:<port>` か `localhost:<port>` のみ受け付ける。
    - `Origin` は付けなくてよい。付ける場合はループバックかつ同じポートでなければならない。
  - **WebSocket**:
    - 接続すると、まず `sessions` が来て、続いて全セッション分の `state` が来る。
    - `attach` に対して、リングバッファを 24 KiB ずつ `replay` で送ってくる。最後のチャンクは `done:true`。
    - replay 中に出た live 出力は 4 MiB までデーモンが溜めておき、replay の後に流す。4 MiB を超えたら `attach_overflow` を返す。
    - 存在しない sid に attach しても、応答は返らない。
    - **detach は無い**。一度 attach した sid は、その接続が続く限り `output` が届き続ける。
    - サーバーは 30 秒ごとに ping を送る。読み取り期限は 60 秒で、**pong を受けたときだけ延長される**。
    - 送信バッファは 256 フレーム。溢れたクライアントは切断される。
    - `resize` は cols / rows の両方が 1〜10000 のときだけ受け付ける。PTY は 1 つなので、複数のクライアントがいると最後の resize が有効になる。
  - **配色**:
    - `internal/osc/color.go` が定義しているのは fg / bg / cursor だけ。
    - Web 版（`web/src/theme.ts`）はこれと同じ値に、選択色（dark `#264f78`、light `#add6ff`）と `minimumContrastRatio: 4.5` を加えている。
    - ANSI 16 色は指定していないので、xterm.js の既定パレット（Tango）が使われている。
    - デーモンは、クライアントが返した OSC 10/11/12 の応答を常に破棄する。
  - **デーモンの起動**:
    - 旧 `desktop/` は `webtabinal-daemon serve` を setsid 付きの `posix_spawn` で起動し、ログを `~/Library/Logs/WebTabinal/daemon.stdio.log` に追記する。
    - 起動後は 0.15 秒間隔で最大 15 秒、待ち受けを確認する。
  - **Web 版で、タブ表示まわりの挙動**:
    - タブごとに xterm を作り直している。
    - サイズの監視は ResizeObserver → `fit()` → `resize` 送信で、デバウンスは無い。
    - 入力はマイクロタスク単位でまとめて送り、replay 中は破棄する。
    - 再接続したら、`reset` → 再 attach → 最後の resize を送り直す。
- 開発機には Command Line Tools しか無い（Xcode は無い）ので、テストは Swift Testing で書く（Phase 0 D5）。

## Goals / Non-Goals

**Goals:**

- SPEC §7 Phase 1 の完了条件を満たす。条件は次の 4 つ。
  - ブラウザ版と同じタブを、同時に表示・操作できる。
  - 主要な TUI が崩れずに表示される。
  - リサイズに追従する。
  - 再接続しても、入力行にゴミが入らない。
- Phase 3 で「全タブを attach したままにする」構成へ広げられるように、セッションごとのコントローラを最初から独立させておく。

**Non-Goals:**

- IME、マウス、選択、コピー＆ペースト、スクロールバック操作。これらは Phase 2。
- サイドバー、複数タブの UI、タブを操作するショートカット。これらは Phase 3。
- 配色の動的な切り替え（system 設定への追従、設定画面からの変更）。Phase 4 で扱う。Phase 1 では、起動時に `color_scheme` を解決して固定する。
- Metal による描画。Phase 5。
- 別エンジン（デーモンの vtscreen）との表示一致テスト。デーモン側にスナップショットを書き出すツールが要るので、Phase 6 に回す。

## Decisions

### D1. モジュールと並行性の境界

```
Tabghostty (@main, AppDelegate, MainWindowController)          @MainActor
 ├ DaemonClient
 │   ├ DaemonConfig        config.json の読み取り（port / auth_token / 表示系の設定）
 │   ├ DaemonLauncher      プローブ・起動・待機（DesktopSupport を利用）
 │   ├ RESTClient          URLSession、Bearer
 │   ├ WSConnection        actor。URLSessionWebSocketTask、再接続、フレームの encode/decode
 │   └ SessionStore        @MainActor。sessions / state / agent_state を反映、アクティブ選択、起動時のセッション確保
 ├ TerminalCore
 │   ├ VTTerminal          C ハンドルのラッパー（Phase 0）+ effect キュー、resize、scrollback
 │   └ TerminalController  actor。セッション 1 つにつき 1 つ。phase、書き込み、effect の振り分け、入力のバッファリング
 ├ TerminalUI
 │   ├ TerminalView        NSView。Core Text 描画、カーソル、サイズ計算、キーイベント
 │   ├ FontResolver / Palette / ContrastAdjuster
 │   └ FrameSnapshot       RenderState からコピーした値型（dirty 行だけ）
 └ DesktopSupport          webtabinal desktop/Sources/DesktopSupport.swift から移植
```

- VT ハンドルに触れるのは `TerminalController`（actor）の中だけにする。spec の「Serialized access」はこれで満たす。
- 描画は次の流れで行う。
  1. actor 内で RenderState を更新する。
  2. dirty 行を値型の `FrameSnapshot` にコピーする。
  3. メインスレッドの `TerminalView` に渡す。

  libghostty のビューは「次の変更操作までしか有効でない」ので、actor の外に参照を持ち出さないための構成。
- 書き込みが立て続けに来る場合は、表示のリフレッシュ 1 回につき 1 回だけ RenderState を更新する。macOS 14 の `NSView.displayLink` を使ってまとめる。

### D2. effect のキューと phase による振り分け

- C の effect コールバックは、`VTTerminal` が持つ配列に積むだけにする。
- `write()` から戻った後に `TerminalController` がキューを取り出し、種類ごとに次のように扱う。

| effect | `.replaying` | `.live` |
|---|---|---|
| PTY 書き戻し | 破棄 | `input` フレームで送信 |
| デスクトップ通知（OSC 9/99/777） | 破棄 | 破棄（デーモンの `notify` に任せる） |
| タイトル | 破棄 | 破棄（タブ名はデーモンの cwd/command から作る） |
| ベル | 破棄 | 破棄（Web 版と同じ。2026-11-09 の判断） |
| クリップボード（OSC 52） | 破棄 | Phase 2 で対応する。それまでは破棄 |

- spec のシナリオ（replay 中の DA / DSR 応答を抑止する）は、モックの WebSocket サーバーを使ったテストで保証する（D7）。
- （Phase 0 の調査結果、`Sources/TerminalCore/README.md`）サイズの問い合わせ（`CSI 14/16/18/19 t`）に応答させるには、`GHOSTTY_TERMINAL_OPT_SIZE` の callback を登録し、最後に `ghostty_terminal_resize` に渡した cols / rows / セルのピクセルサイズを返す必要がある。未登録だとライブラリは黙って無視する。
- 同じく、スクロールバックの上限は既定で 10,000 バイト（実際には 1 ページ）なので、`GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES = SIZE_MAX` と `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES = scrollback_lines` を設定する。
  - 行数の上限を設定しても、libghostty が削除するのはページ単位なので、内部には上限より多くの行が残る（2026-11-09 の計測: 上限 100 行・80 列で 500 行を流すと 477 行残る）。
  - そのため、spec は「保持する」ではなく「見せる」行数を上限にする（2026-11-09 の判断）。`VTTerminal.scrollbackRows` は上限で丸めた行数を返す。Phase 2 のスクロール（viewport を動かせる範囲）と Phase 5 の検索・テキストの取り出しも、最新の `scrollback_lines` 行より古い行に届かないよう、この値で範囲を丸める。

### D3. attach、再接続、overflow

`TerminalController` の状態遷移:

```
detached ──attach()──▶ replaying ──replay done──▶ live
   ▲                        │ attach_overflow / 再接続
   └──── reset() ◀──────────┘ （どの状態からでも reset → attach へ戻る）
```

- `done:true` を受けたら live に移り、そのビューの現在のグリッドサイズで `resize` を送る。
- 再接続したときは、`SessionStore` が表示中の全コントローラに対して reset → attach を指示する。
- detach は存在しないので、表示しなくなったセッションの `output` も届き続ける。Phase 1 では表示中のセッションにしか書き込まず、それ以外の sid の `output` は捨てる。Phase 3 で、全セッションに書き込む方式に変える。

### D4. WebSocket の実装

- `URLSessionWebSocketTask` を使う。
  - `URLRequest` で `Authorization` を設定する。
  - `Origin` は設定しない。URLSession が自動で付けるかどうかは、テストで確認する。
- ping への pong は URLSession が自動で返す想定。5 分間アイドルにしても切れないことを、手動テストで確認する。
- 受信ループは専用の Task で回し続け、デコードしたフレームは actor に渡すだけにする。256 フレームの送信バッファを溢れさせないため、受信を止めないことを優先する。
- 再接続の待ち時間は `min(500 * 2^n, 5000)` ms で、Web 版と同じ。接続に成功したら n を 0 に戻す。
- 入力は sid ごとに次のランループの周回まで溜め、まとめて 1 つの `input` フレームで送る（Web 版のマイクロタスク単位のまとめ送りに相当）。切断中に作られた入力は捨てる。

**採用しなかった案:**

- Network.framework の `NWProtocolWebSocket`: `autoReplyPing` を明示できる利点はあるが、HTTP ヘッダの付け方が煩雑になる。URLSession で pong が返らないと分かった場合の代替として残す（Risks を参照）。

### D5. フォント、セル寸法、配色

- **フォント**:
  - `font_family` をカンマで区切り、各要素の前後の空白と引用符を取り除く。
  - 先頭から順に `NSFontManager` で存在を確かめ、最初に見つかったものを使う。
  - `monospace` は `NSFont.monospacedSystemFont(ofSize:weight:)` に対応させる。
  - 太字と斜体は `NSFontManager.convert(_:toHaveTrait:)` で作る。
  - フォールバックは `CTFontCreateForString` で作り、結果はキャッシュする。
- **セル寸法**:
  - 幅は `M` の advance、高さは ascent + descent + leading。
  - `backingScaleFactor` を掛けて device pixel に丸める。
  - cols / rows は `floor((view - 2×4pt) / cell)` で求める。
  - リサイズは 50 ms デバウンスし、cols / rows が変わったときだけ Terminal の resize と `resize` フレームの送信を行う。Web 版にはデバウンスが無いが、ネイティブのライブリサイズでは大量にイベントが出るため、SPEC §5.1 に従って入れる。
- **配色**: `Palette` に次を定数として持つ。
  - dark / light それぞれの fg / bg / cursor / 選択色（`internal/osc/color.go` と `web/src/theme.ts` に一致させる）。
  - ANSI 16 色（xterm.js の既定値）: `#2e3436 #cc0000 #4e9a06 #c4a000 #3465a4 #75507b #06989a #d3d7cf #555753 #ef2929 #8ae234 #fce94f #729fcf #ad7fa8 #34e2e2 #eeeeec`。
  - 256 色の 6×6×6 キューブとグレースケールは、xterm 標準の式で求める。
- **コントラスト補正**: xterm.js の `minimumContrastRatio` と同じ考え方で実装する。WCAG の相対輝度を使い、比率が 4.5 に届くまで前景色を明るく（または暗く）していく。純粋関数として切り出し、ユニットテストで確認する。
- **配色の選び方**: `color_scheme` が `light` / `dark` ならその値を使う。`system` なら起動時の `NSApp.effectiveAppearance` で決める。設定の変更や system 側の変化に追従するのは Phase 4。

### D6. 描画（Core Text）

- `TerminalView.draw(_:)` の処理:
  1. dirty 行の背景色を、同じ色が続く区間ごとにまとめて塗る。
  2. 同じスタイルが続く区間ごとに `CTLine` を作り、グリフを描く。
  3. 下線と打ち消し線を描く。
  4. カーソルを描く。
- 全角文字は libghostty のセル幅情報（wide と spacer）に従う。グリフは 2 セル分の幅に描き、spacer セルは描かない。
- **カーソル**:
  - 形状と表示 / 非表示は RenderState の値を使う。
  - 点滅は約 530 ms のタイマーで行い、ビューがフォーカスを持っている間だけ点滅させる。
  - フォーカスが無いときは、中抜きのブロックで描く。
- 再描画は `setNeedsDisplay(rect)` で dirty 行の範囲だけに絞る。カーソルの点滅では、カーソルのあるセルだけを再描画する。

### D7. テストの構成

**DaemonClientTests**

- テスト用のモック WebSocket サーバーを `NWListener` + `NWProtocolWebSocket` で用意する。シナリオ:
  1. `sessions` → `attach` → `replay` を 3 分割 → `output`。
  2. `attach_overflow` → reset → attach し直し。
  3. replay 中に `ESC[c` と `ESC[6n` を流しても `input` が出ないこと。live になってから同じものを流すと `input` が出ること（SPEC §8.1 の「replay 中の応答抑止」）。
  4. 切断 → 指数バックオフで再接続 → 表示中のセッションを attach し直し、`resize` を送り直すこと。
- `Authorization` が付き、`Origin` が付かないこと。
- エラーメッセージにトークンが含まれないこと。
- config.json の読み取り（既定ポート、不正なポート）。

**TerminalCoreTests**

- effect の順序。
- `CSI 16 t` の応答（セルのピクセルサイズ）。
- スクロールバックの上限。
- 並行してアクセスしてもクラッシュしないこと。
- フィクスチャを 3 通りの分割で書き込んでも、結果が同じになること。

**TerminalUITests**

- フォントスタックの解決。
- パレットの値（daemon と一致すること）。
- コントラスト補正。
- グリッドサイズの計算（パディング、丸め、1 セル未満の変化では送らないこと）。

**DesktopSupport**

- 旧 `desktop/Tests/main.swift` のうち、移植した部分（ポートの解析、プローブ応答の判定、デタッチ起動）を Swift Testing に移す。
- SPEC §10-6 に従い、まずそのまま移設してテストを通す。その後で不要な部分（WebKit の JS ブリッジなど）を削る。

### D8. `.app` のビルド（`scripts/build-app.sh`）

1. `swift build -c release`。
2. デーモンを用意する。`WEBTABINAL_DAEMON` が指定されていればそれを使う。無ければ `make -C "${WEBTABINAL_DIR:-../webtabinal}" build` を実行し、`bin/webtabinal` を使う。どちらも無ければ、2 つの変数名を出して失敗する。
3. `build/Tabghostty.app` を作り、`Contents/MacOS/` に実行ファイルを置き、デーモンを `webtabinal-daemon` として置く。
4. `Info.plist` の内容:
   - `CFBundleIdentifier=com.tabghostty.app`（`com.webtabinal.app` とは別にして、両方のアプリを同時に動かせるようにする）
   - `CFBundleName=Tabghostty`
   - `LSMinimumSystemVersion=14.0`
   - `NSHighResolutionCapable`
   - `TabghosttyDaemonRevision`（webtabinal の `git rev-parse HEAD`。プレビルドのバイナリを使った場合は `prebuilt`）
5. ad-hoc で codesign する。

補足:

- デーモン実行ファイルの場所は、`Bundle.main` の実行ファイルと同じディレクトリから探す。`swift run` で開発するときのために、環境変数 `TABGHOSTTY_DAEMON_PATH` で上書きできるようにする。
- アイコンは Phase 7 で用意する。それまでは既定のアイコンでよい。

### D9. フィクスチャの取り込み

- `scripts/sync-fixtures.sh` で、`$WEBTABINAL_DIR/tests/fixtures/agents` を `Tests/Fixtures/agents/` へ丸ごとコピーし、`Tests/Fixtures/SOURCE` に webtabinal のコミットを記録する。
- 全部で約 250 KB（`stream.raw` の合計は約 5 KB）と小さいので、リポジトリにコミットする。
- テストは `metadata.json` の `rows` / `columns` で Terminal を作り、`stream.raw` を流す。期待する画面テキストはフィクスチャに含まれていない（webtabinal 側にも無い）ので、Phase 1 では「分割の仕方によらず結果が同じ」ことだけを検証する。

## Risks / Trade-offs

- **[Risk] 同じセッションに複数のクライアントが attach すると、端末問い合わせに両方が応答する**（ブラウザ版とネイティブ版を併用した場合）。→ 現行のブラウザ 2 窓と同じ挙動なので、Phase 1〜4 では許容する（SPEC §9）。根本的な対処はデーモン側の調停で、Phase 6 以降の別タスクとする。
- **[Risk] 複数のクライアントがいると、PTY のサイズは最後に resize したものになる。** そのため、サイズの違うクライアントでは表示が崩れる。→ 現行と同じ制約。live になったときとフォーカスを得たときに、`resize` を送り直して緩和する。
- **[Risk] `URLSessionWebSocketTask` が ping に pong を自動で返さない**と、60 秒で切断される。→ 手動テスト（5 分間アイドル）で確認する。返らない場合は、`NWProtocolWebSocket`（`autoReplyPing = true`）に切り替える。`WSConnection` の内側だけの差し替えで済む。
- **[Risk] replay の先頭が、壊れたシーケンスで始まることがある**（バイト境界を考慮していないため）。→ libghostty のパーサが不正なシーケンスを無視して回復することを、先頭を数バイト削ったフィクスチャのテストで確認する。根本的な解決は Phase 6 の Snapshot による replay。
- **[Risk] 起動中のデーモンと同梱デーモンのバージョンが違う。** たとえば WebTabinal.app が起動した古いデーモンにつながる場合。→ プロトコルが変わっていないので動作はする。README に「デーモンを更新するときは `pkill -f 'webtabinal-daemon serve'`」と書く（Phase 7 で README を整理する）。
- **[Trade-off] Core Text で描画するので、大量の出力では遅い。** → Phase 1 は正しさを優先する。性能は Phase 5 の Metal と完了条件で担保する。

## Migration Plan

新規機能なので、移行の手順はない。WebTabinal.app と並行して使える（バンドル ID が別）。

## Open Questions

- カーソルの点滅間隔（SPEC は約 530 ms。xterm.js の既定値とは多少違う可能性がある）。実機で見比べて調整すればよく、spec には影響しない。
