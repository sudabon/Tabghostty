# Design: Phase 6（任意）— デーモン側の libghostty-vt 化と転送の強化

## Context

- **方針の変更（2026-11-09）**
  - 当初の方針は「Tabghostty はクライアント専用。デーモンの変更は webtabinal の change で行う」だった。しかし、webtabinal は変更しないことになった。
  - そこで、デーモンの Go のコードを Tabghostty の `daemon/` に取り込む（D0）。D1〜D3 は、その中で実装する。
  - Tabghostty.app に同梱するデーモンは、`daemon/` からビルドする。webtabinal のリポジトリは、Web 版の画面のビルドにだけ使う。
- 取り込み元: webtabinal `6dca08f` の現状
  - **`vtscreen.Screen` インタフェース**: `Feed`、`Resize`、`Snapshot(SnapshotOptions{Buffer, Lines})`、`Close` の 4 つ。`Snapshot` が返すのは `{Available, Buffer, Active, Cols, Rows, Lines}`。
  - **行の正規化**: 表示中の行だけを対象にし、末尾の空白を削り、wide 文字の継続セルを飛ばし、結合文字は前の文字に付ける。スクロールバックは 1 行。
  - **`adapter.go` の `splitAltTransitions`**: 47 / 1047 / 1049 を含む `CSI ? … h/l` の位置でチャンクを分け、分けた区切りごとに画面を保存する。
  - **`conformance.go`**: Go で書いた 8 つの適合ケースがある。
  - **フィクスチャ**（`tests/fixtures/agents`、21 シナリオ）
    - 期待する画面テキストを持っていない。
    - 画面を書き出すツールも無い。ただし、非公開の `agentdetect.replayFixture` が、同じ処理をしている。
    - `agentfixtures.Root()` は、`go.mod` のあるディレクトリから `tests/fixtures/agents` を探す。
  - **WebSocket**: JSON のテキストフレームだけを使う。`clientMsg` を読むときに未知のフィールドを無視する（Go の `encoding/json` の既定）ので、`attach` に `binary` を足しても、古いデーモンはそれを無視する。
  - **ビルド**: `make build` は、`web/` の `npm run build` の成果物を `internal/static/dist` にコピーし、`go build ./cmd/webtabinal` で埋め込む。`dist` が無いと、プレースホルダの画面を埋め込む。
- **Go バインディング `go.mitchellh.com/libghostty`**
  - 作者は API の安定性を約束していない（SPEC §7 Phase 6 の注意）。
  - リンク先は pkg-config（`libghostty-vt-static`）で受け取る。
  - 2026-11-09 に確かめた結果:
    - `v0.0.0-20261107144202-b13f277ddcb2` は、Tabghostty の `Vendor/GhosttyVt.xcframework`（1.0.0）の静的ライブラリにリンクできる。
    - `Version()` は `1.0.0` を返す。
    - pkg-config の代わりに、`PKG_CONFIG` に小さなスクリプトを渡せばよい（zig も pkg-config も要らない）。

## Goals / Non-Goals

**Goals:**

- 同梱するデーモンの画面モデルを、libghostty-vt を使う実装に切り替える。タグなしの既定のビルドは、従来の実装のままにする。
- 既存の受け入れテストを、`-tags ghostty` 付きで通す。
- Tabghostty とデーモンの両方のエンジンが同じ画面を作ることを、フィクスチャで継続的に検証する。
- 出力を転送するときの JSON と base64 のオーバーヘッドを、互換性を保ったまま無くす。
- webtabinal のリポジトリを変更しない。

**Non-Goals:**

- Snapshot を使った replay の実装（検討して記録するだけ）。ブラウザ版の xterm.js は Snapshot を読めないので、ネイティブ専用のフレームを追加することになる。その影響を検討してから、別の change で扱う。
- 複数のクライアントが端末問い合わせに重複して応答する問題の調停（SPEC §9。別のタスク）。
- Web 版の画面（`web/`）の取り込み。
- webtabinal 本体の修正を、同梱版へ自動で取り込む仕組み（手順を `daemon/UPSTREAM.md` に書くだけ）。

## Decisions

### D0. デーモンを `daemon/` に取り込む

- **コピーするもの**: webtabinal `6dca08f` の `go.mod`、`go.sum`、`cmd/`、`internal/`、`tests/fixtures/agents/`、`LICENSE`（MIT。著作権者は同じ）。あわせて `scripts/record-agent-fixture.sh` もコピーする（`internal/agentfixtures` のテストが実行するため。無いと取り込み元のテストが通らない）。
- **コピーのしかた**: `git archive` で、追跡されているファイルだけを取り込む。
- **コピーしないもの**: `web/`、`desktop/`、そのほかの `scripts/`、`openspec/`、`docs/`、`Makefile`。
- **モジュールのパス**: `github.com/sudabon/webtabinal` のまま変えない。import を書き換えずに済むので、取り込み元との差分が小さく保てる。
- **Tabghostty で加える変更**: できるだけ新しいファイルに分ける。取り込み元のファイルを変えるのは、次のものだけにする。
  - `go.mod` と `go.sum`（バインディングの追加）
  - `internal/vtscreen/adapter.go`（`Open` の名前を変える）
  - `internal/vtscreen/adapter_test.go`（charmbracelet の実装を直接作る）
  - `internal/server/ws.go`（バイナリフレーム）
  - `internal/static/dist` は、取り込み元と同じく `.gitkeep` だけをコミットする。
- **`daemon/UPSTREAM.md` に書くこと**
  - 取り込み元のコミット
  - コピーした範囲
  - 加えた変更の一覧
  - webtabinal 本体の修正を取り込む手順（コピーし直して、一覧の変更を当て直す）

### D1. `daemon/internal/vtscreen/ghostty.go`

- 先頭に `//go:build ghostty` を付け、`Screen` を実装する。
- **`Open` の切り替え**
  - `adapter.go` の `Open` を `openCharm` に改名する。
  - `open_charm.go`（`//go:build !ghostty`）と `ghostty.go` が、それぞれ `Open` を定義する。
  - 使っている画面モデルの名前を `vtscreen.ModelName`（`"charmbracelet"` / `"ghostty"`）で公開する。
- **`Open`**: 指定されたサイズで Terminal を作る。スクロールバックは最小（`WithMaxScrollbackLines(0)`）にする。
- **PTY への書き戻し**: effect は登録しない（バインディングの既定で捨てられる。今の `drainEmulatorReplies` に相当）。
- **`Feed`**: 今の `adapter.go` と同じく、`splitAltTransitions` でチャンクを分ける。
  - libghostty は、アクティブな画面（`ActiveScreen()`）の grid しか読めない。そこで、alternate screen の切り替えのチャンクを書く直前に、離れる画面の行を保存する。
  - アクティブな画面の行は、`Snapshot` のときに読む（書き込みがあったときだけ）。
  - charmbracelet 版は、チャンクごとに全セルを読み直す。それと同じスナップショットになり、PTY を読むたびに全セル分の cgo 呼び出しをせずに済む。
- **行の読み方**
  - active area のセルを `GridRef(Point{Tag: PointTagActive})` で読む。
  - wide 文字の継続セル（`CellWideSpacerTail`）は飛ばす。
  - 文字の無いセルは空白にし、書記素（`Graphemes()`。結合文字を含む）を並べてから、`strings.TrimRight(s, " ")` で末尾の空白を削る。
  - Tabghostty の `ScreenNormalizer` と同じ規則にする。
- **排他制御**: ハンドルはゴルーチンセーフではないので、今と同じく mutex で守る。panic は今と同じく回収して、画面モデルを使えない状態にする。
- **リンク**
  - `go.mod` には、`go.mitchellh.com/libghostty` を `v0.0.0-20261107144202-b13f277ddcb2` で固定する。
  - リンク先は `daemon/scripts/pkg-config` で渡す。このスクリプトは、`libghostty-vt-static` についてだけ、`Vendor/GhosttyVt.xcframework/macos-arm64_x86_64` のヘッダと静的ライブラリを答える。
  - ビルドは `PKG_CONFIG=daemon/scripts/pkg-config CGO_ENABLED=1 go build -tags ghostty` で行う（Makefile の `daemon` ターゲット）。
- **受け入れ条件**
  - `go test -race -tags ghostty ./internal/vtscreen/... ./internal/agentdetect/... ./internal/session/...` が通ること（`conformance.go`、`contract_test.go`、`fixtures_test.go` を含む）。
  - 既定のビルドで `go test ./...` が、取り込み元と変わらず通ること。

### D2. フィクスチャの最終画面を書き出す（`daemon/internal/agentdetect/screens_test.go`）

- `internal/agentdetect` に、テスト専用のフラグ `-update-screens` を付けたテストを追加する。
  - `replayFixture` と同じ手順でフィクスチャを流す（`metadata.json` のサイズで `vtscreen.Open` → 各ステップを `Feed` → `Snapshot(BufferActive, Lines: rows)`）。
  - 結果を `tests/fixtures/agents/<…>/screen.txt` に書き出す。
- **生成するビルド**: `screen.txt` を生成するのは、`-tags ghostty` 付きのビルドだけにする。既定のビルドでフラグを付けたときは、生成せずに skip する（charmbracelet の出力との比較用ファイルは作らない）。
- **古くなっていないかの確認**: `-tags ghostty` 付きのビルドでフラグを付けないときは、コミット済みの `screen.txt` が、今の画面モデルの出力と同じであることを確かめる。画面モデルを変えたのに `screen.txt` を作り直していなければ、ここで失敗する。
- **形式**（Tabghostty の `EngineParityTests` が読む）
  - `screen.txt`: `Snapshot.Lines` の各行を UTF-8 で書き、各行の後ろに `\n` を付ける（行数はフィクスチャの `rows` と同じ）。最後の `\n` の後ろは行に数えない。
  - `screen.meta.json`: `{"screen_model": "ghostty", "libghostty_vt_version": "<libghostty.Version() の値>"}`。値は、ヘッダの版ではなく、実行時の `ghostty_version()`（開発版なら `1.1.0-dev+abc1234` のような形）にする。
- **リビジョンの記録**: 生成したリビジョンは、`scripts/sync-fixtures.sh` が `Tests/Fixtures/SOURCE` に記録する（`commit` と `reference_screens`）。
- **Makefile**: `make screens` で生成し、続けて `make fixtures` で `Tests/Fixtures` に取り込む。

### D3. バイナリフレーム（`daemon/internal/server/ws.go`）

- クライアントが `{"t":"attach","sid":"…","binary":true}` を送ったら、その接続のその sid についてだけ、`output` と `replay` をバイナリのメッセージで送る。
  - attach のたびに、そのときの値で決め直す。
  - attach の間にためた出力（`flushAttachPending`）も、同じ形式で送る。
- `sessions`、`state`、`agent_state`、`notify`、`error` は、これまでどおり JSON で送る。
- **形式**（spec: bundled-daemon「Binary output frames format」を正とする）:

  ```
  byte 0      : 種類  0x01=output, 0x02=replay（続きあり）, 0x03=replay（最後のチャンク、done=true）
  byte 1      : sid の長さ N（UUID なら 36。1〜255）
  byte 2..2+N : sid（ASCII）
  残り         : PTY のバイト列（そのまま）
  ```

- **例外**
  - sid が ASCII でない場合や、256 バイト以上の場合は、その sid についてだけ JSON で送る。
  - リングバッファが空なら、payload が空の 0x03 を 1 つ送る（JSON の `{"data":"","done":true}` に相当）。
- **送信キュー**: 1 つのメッセージを「テキストかバイナリか」と「バイト列」の組にする（`writeClient` が `WriteMessage` の種類を選ぶ）。

### D4. Tabghostty 側: 受信は両方の形式に対応する

- `WSConnection` は、`URLSessionWebSocketTask.Message` の `.data` と `.string` の両方を受け取り、どちらも内部の `ServerFrame` に変換する。
- `attach` には常に `binary: true` を付ける。宣言を無視するデーモン（webtabinal 本体、古い同梱版）は、JSON で動き続ける。どちらで動くかを判定する処理は持たない。
- `.data` のメッセージは、先頭のバイトが D3 の種類（0x01〜0x03）なら D3 の形式で読み、そうでなければこれまでどおり JSON として読む。どちらとしても読めないものは、接続を切らずに無視する。
- モック WS サーバーで、次の 3 つを同じテストの流れで確認する。
  - JSON だけの場合
  - バイナリだけの場合
  - 両方が混ざる場合（`replay` は JSON、`output` はバイナリ）

### D5. Tabghostty 側: エンジンの一致検証

- **`scripts/sync-fixtures.sh`**
  - 取り込み元の既定を `daemon/` にする（`FIXTURES_SOURCE_DIR` で変えられる）。
  - `screen.txt` と `screen.meta.json` もコピーする。
  - `screen.txt` が有るのに `screen.meta.json` が無いフィクスチャがあれば、取り込まずに失敗する。
- **一致検証のテストの流れ**
  1. `screen.meta.json` に記録された libghostty-vt のバージョンが、Tabghostty がリンクしているもの（`ghostty_version()`。`scripts/libghostty.lock` の版で取得した XCFramework）と一致するかを確かめる。一致しなければ、両方のバージョンを出して失敗する。lock ではなくリンクしている値と比べるのは、spec の「The libghostty-vt version Tabghostty links」に合わせるため（lock を上げて `make deps` を忘れた場合も検出できる）。
  2. フィクスチャを流し、正規化した結果を `screen.txt` と比べる。
- **正規化の処理（`ScreenNormalizer`）**: `TerminalCore` に置く。表示中の行を、末尾の空白を削り、継続セルを飛ばし、結合文字を前の文字に付けて、テキストにする。
  - セルは grid ref（`GHOSTTY_POINT_TAG_ACTIVE`）で読む。RenderState の更新は Terminal の dirty を消費するので、描画中の端末で使っても次のフレームが欠けないようにするため。
  - 削る空白は U+0020 だけ（Go の `strings.TrimRight(s, " ")` と同じ）。
- **skip の扱い**: `screen.txt` の無いフィクスチャは、テストケースを `Test.cancel` で skip する。`swift test` のコンソールでは、cancel したケースは passed と表示される（event stream では `testCaseCancelled`）。そのため、何件で一致を検証したかを 1 行出力する。
- **同じ libghostty を使う**: デーモンと Tabghostty は、同じ `Vendor/GhosttyVt.xcframework` にリンクする（D1）。そのため、バージョンは構造上ずれない。照合は、XCFramework を差し替えたのに `screen.txt` を作り直し忘れた場合の検出になる。

### D6. Snapshot を使った replay の検討（ADR）

`docs/adr/0001-snapshot-replay.md` に、次の点を比べた結果を書く。

- 方式案: デーモンが `attach` に対して、`replay` の代わりに `snapshot` フレーム（libghostty の Terminal Snapshot）を送る。
- ネイティブ専用のフレームを追加することになる。ブラウザ版との互換性をどう保つか。
- Snapshot の大きさと、エンコード・デコードにかかる時間。
- 今の「replay が壊れたシーケンスから始まる」問題が解消されるか。
- デーモン側で Terminal を保持するためのメモリ使用量（今の 5 MiB のリングバッファとの比較）。

### D7. 同梱するデーモンのビルド

- **`make daemon`**: `daemon/bin/webtabinal` を `-tags ghostty` でビルドする。
- **`make daemon-test`**: 次の 2 つを実行する。
  - 既定のビルドでの `go test ./...`
  - `-tags ghostty -race` での D1 の受け入れテスト
- **`make app`**（`scripts/build-app.sh`）
  1. Web 版の画面を `../webtabinal/web` で `npm run build` する。成果物（`web/dist`。webtabinal では gitignore 済み）を、`daemon/internal/static/dist` にコピーする。webtabinal で生成されるのは、gitignore されたビルド成果物だけで、ソースは変えない。
  2. `make daemon` でビルドしたデーモンを `Contents/MacOS/webtabinal-daemon` として同梱する。
  3. Info.plist の `TabghosttyDaemonRevision` には、`tabghostty-<Tabghostty のコミット>` を記録する。`daemon/` に未コミットの変更があれば、`-dirty` を付ける。
- **Web 版が無い場合**: `../webtabinal` が無いときは、警告を出してプレースホルダの画面のまま同梱する（ネイティブ版は動く）。
- **ビルド済みのデーモン**: `WEBTABINAL_DAEMON` でビルド済みのデーモンを指定する方法は残す。

## Risks / Trade-offs

- **[Risk] Go バインディングの API が変わる。** → コミットで固定し、ビルドタグで既定のビルドから隔離する。更新するときは、D1 の受け入れテストと D5 の一致検証を必ず通す。
- **[Risk] 同梱版が webtabinal 本体から遅れる。** エージェントの検出の修正などは、自動では入らない。→ 取り込み元のコミットと、加えた変更の一覧を `daemon/UPSTREAM.md` に記録する。変更はできるだけ新しいファイルに分け、取り込み直しの手間を小さくする。
- **[Risk] 同じ設定ファイルを使うデーモンが 2 種類ある。** webtabinal 本体と同梱版の、どちらが起動していても、Tabghostty は接続できる。→ バイナリフレームは宣言制なので、本体のデーモンにつないでも JSON で動く（D4）。
- **[Trade-off] 一致を検証できるのは `ghostty` タグでビルドしたデーモンとだけ。** 既定のビルド（charmbracelet）とは一致しない部分が残る。→ 同梱版は `ghostty` タグでビルドするので、Tabghostty.app の利用者にとっては問題にならない。
- **[取り込み元の既知の問題] 既定のビルドの `-race` が失敗する。** charmbracelet/x/vt の `Emulator.Close` と `drainEmulatorReplies` の data race で、取り込み元の `6dca08f` でも、`internal/vtscreen` とセッションを作る `internal/server` のテストが失敗する。→ 直さない（取り込み元の問題で、同梱版は ghostty のビルドなので影響しない）。`make daemon-test` は、既定のビルドを `-race` なしで、ghostty のビルドを `-race` 付きで実行する。charmbracelet の内部を調べる 2 つのテストは、ghostty のビルドでは skip する。
- **[Trade-off] 同梱版のビルドに cgo と XCFramework が要る。** `make app` には、もともと `make deps` が必要なので、手順は増えない。

## 結果（2026-11-09）

- **一致検証**: 全 21 フィクスチャで、同梱のデーモン（ghostty のビルド）の `screen.txt` と、Tabghostty の `ScreenNormalizer` の出力が、行ごとのバイト列で一致した（`EngineParityTests`）。一致しないものは無かったので、どちらかで直す必要は無かった。
- **デーモンのテスト**: `make daemon-test` が通る。内容は、既定のビルドの `go test ./...` と、`-race -tags ghostty ./...` の 2 つ。
- **`make app`**
  - 同梱したデーモンのビルド設定に `-tags=ghostty` がある（`go version -m`）。libghostty-vt は静的にリンクされる。
  - Web 版の画面が埋め込まれている。
  - webtabinal の `git status` には変更が無い。
- **バイナリフレームの形式**: Go のエンコーダと Swift のデコーダが、同じゴールデンのバイト列（`ws_binary_test.go` と `BinaryFrameTests.swift`）で一致する。
