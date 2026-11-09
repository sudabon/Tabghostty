# Design: Phase 6（任意）— デーモン側の libghostty-vt 化と転送の強化

## Context

- **Tabghostty はクライアント専用**（2026-11-09 決定）。デーモンを変更する作業は、webtabinal リポジトリの OpenSpec change として起票し、そちらで実装・archive する。この change が持つのは次の 3 つ。
  - Tabghostty 側の実装
  - webtabinal に渡す変更案（D1〜D3）
  - 両リポジトリの作業をつなぐタスク
- webtabinal `6dca08f` の現状:
  - **`vtscreen.Screen` インタフェース**: `Feed`、`Resize`、`Snapshot(SnapshotOptions{Buffer, Lines})`、`Close` の 4 つ。`Snapshot` が返すのは `{Available, Buffer, Active, Cols, Rows, Lines}`。
  - **行の正規化**: 表示中の行だけを対象にし、末尾の空白を削り、wide 文字の継続セルを飛ばし、結合文字は前の文字に付ける。スクロールバックは 1 行。
  - **`adapter.go` の `splitAltTransitions`**: 47 / 1047 / 1049 を含む `CSI ? … h/l` の位置でチャンクを分け、分けた区切りごとに画面を保存する。
  - **`conformance.go`**: Go で書いた 8 つの適合ケースがある。
  - **フィクスチャ**（`tests/fixtures/agents`、21 シナリオ）:
    - 期待する画面テキストを持っていない。
    - 画面を書き出すツールも無い。ただし、非公開の `agentdetect.replayFixture` が、同じ処理をしている。
    - `agentfixtures` と `vtscreen` は `internal/` にあるので、書き出す仕組みは webtabinal のモジュールの中に置く必要がある。
  - **WebSocket**: JSON のテキストフレームだけを使う。`clientMsg` を読むときに未知のフィールドを無視する（Go の `encoding/json` の既定）ので、`attach` に `binary` を足しても、古いデーモンはそれを無視する。
- Go バインディング `go.mitchellh.com/libghostty` について、作者は API の安定性を約束していない（SPEC §7 Phase 6 の注意）。

## Goals / Non-Goals

**Goals:**

- デーモンの画面モデルを、libghostty-vt を使う実装に切り替えられるようにする。既定は従来の実装のままにする。
- 既存の受け入れテストを、`-tags ghostty` 付きで通す。
- Tabghostty とデーモンの両方のエンジンが同じ画面を作ることを、フィクスチャで継続的に検証する。
- 出力を転送するときの JSON と base64 のオーバーヘッドを、互換性を保ったまま無くす。

**Non-Goals:**

- Snapshot を使った replay の実装（検討して記録するだけ）。ブラウザ版の xterm.js は Snapshot を読めないので、ネイティブ専用のフレームを追加することになる。その影響を検討してから、別の change で扱う。
- 複数のクライアントが端末問い合わせに重複して応答する問題の調停（SPEC §9。別のタスク）。
- 既定のビルドを `ghostty` タグに切り替えること。

## Decisions

### D1. webtabinal に渡す変更案: `internal/vtscreen/ghostty.go`

- 先頭に `//go:build ghostty` を付け、`Screen` を実装する。
  - `Open`: 指定されたサイズで Terminal を作る。スクロールバックは最小にする。
  - **PTY への書き戻し effect は、何もしない関数**にする（今の `drainEmulatorReplies` に相当）。
  - `Feed`: 今の `adapter.go` と同じく `splitAltTransitions` でチャンクを分け、区切りごとに primary 画面と alternate 画面のスナップショットを更新する。
  - `Snapshot`: libghostty のフォーマッタ（plain）、または RenderState の行から、今と同じ正規化をした `Lines` を返す。
  - ハンドルはゴルーチンセーフではないので、今と同じく mutex で守る。
- `go.mod` には、`go.mitchellh.com/libghostty` を特定のコミット（擬似バージョン）で固定する。
- 受け入れ条件: `go test -race -tags ghostty ./internal/vtscreen/... ./internal/agentdetect/... ./internal/session/...` が通ること（`conformance.go`、`contract_test.go`、`fixtures_test.go` を含む）。既定のビルドで `go test ./...` が今と変わらず通ること。

### D2. webtabinal に渡す変更案: フィクスチャの最終画面を書き出す

- `internal/agentdetect` に、テスト専用のフラグ `-update-screens` を付けたテストを追加する。
  - `replayFixture` と同じ手順でフィクスチャを流す（`metadata.json` のサイズで `vtscreen.Open` → 各ステップを `Feed` → `Snapshot(BufferActive, Lines: rows)`）。
  - 結果を `tests/fixtures/agents/<…>/screen.txt` に書き出す。
- 書き出すときは、`screen.meta.json` も作る。中身は、使った画面モデル（`ghostty` か `charmbracelet`）と、libghostty-vt のバージョン。
- `screen.txt` を生成するのは、`-tags ghostty` 付きのビルドだけにする。既定のビルドでの出力は、比較用に `screen.charmbracelet.txt` として残してもよい。どちらにするかは webtabinal 側で決める。

### D3. webtabinal に渡す変更案: バイナリフレーム

- クライアントが `{"t":"attach","sid":"…","binary":true}` を送ったら、その接続のその sid についてだけ、`output` と `replay` をバイナリのメッセージで送る。
- `sessions`、`state`、`agent_state`、`notify`、`error` は、これまでどおり JSON で送る。
- **形式（案）**:

  ```
  byte 0      : 種類  0x01=output, 0x02=replay（続きあり）, 0x03=replay（最後のチャンク、done=true）
  byte 1      : sid の長さ N（UUID なら 36）
  byte 2..2+N : sid（ASCII）
  残り         : PTY のバイト列（そのまま）
  ```

- 形式を最終的に決めるのは、webtabinal 側の change。Tabghostty はそれに従って実装する。決まった形式は、webtabinal の spec（`transport-api`）を正とする。

### D4. Tabghostty 側: 受信は両方の形式に対応する

- `WSConnection` は、`URLSessionWebSocketTask.Message` の `.data` と `.string` の両方を受け取り、どちらも内部の `SessionFrame` に変換する。
- `attach` には常に `binary: true` を付ける。古いデーモンはこのフィールドを無視するので、JSON で動き続ける。どちらで動くかを判定する処理は持たない。
- モック WS サーバーで、次の 3 つを同じテストの流れで確認する。
  - JSON だけの場合
  - バイナリだけの場合
  - 両方が混ざる場合（`replay` は JSON、`output` はバイナリ）

### D5. Tabghostty 側: エンジンの一致検証

- `scripts/sync-fixtures.sh` が、`screen.txt` と `screen.meta.json` もコピーするようにする。
- 一致検証のテストの流れ:
  1. `screen.meta.json` に記録された libghostty-vt のバージョンが、`scripts/libghostty.lock` と一致するかを確かめる。一致しなければ、両方のバージョンを出して失敗する。
  2. フィクスチャを流し、正規化した結果を `screen.txt` と比べる。
- 正規化の処理（`ScreenNormalizer`）は `TerminalCore` に置く。表示中の行を、末尾の空白を削り、継続セルを飛ばし、結合文字を前の文字に付けて、テキストにする。

### D6. Snapshot を使った replay の検討（ADR）

`docs/adr/0001-snapshot-replay.md` に、次の点を比べた結果を書く。

- 方式案: デーモンが `attach` に対して、`replay` の代わりに `snapshot` フレーム（libghostty の Terminal Snapshot）を送る。
- ネイティブ専用のフレームを追加することになる。ブラウザ版との互換性をどう保つか。
- Snapshot の大きさと、エンコード・デコードにかかる時間。
- 今の「replay が壊れたシーケンスから始まる」問題が解消されるか。
- デーモン側で Terminal を保持するためのメモリ使用量（今の 5 MiB のリングバッファとの比較）。

## Risks / Trade-offs

- **[Risk] Go バインディングの API が変わる。** → コミットで固定し、ビルドタグで既定のビルドから隔離する。更新するときは、D1 の受け入れテストと D5 の一致検証を必ず通す。
- **[Risk] デーモンと Tabghostty で、libghostty-vt のバージョンがずれる。** → D5 でバージョンを照合し、ずれたらテストを失敗させる。バージョンを上げるときは、両方のリポジトリで同時に上げる手順を README に書く。
- **[Risk] 2 つのリポジトリにまたがるので、片方だけが先にマージされる。** → バイナリフレームは、どちらが先に入っても動くように作る（D3 と D4）。一致検証は、`screen.txt` が無ければ skip する（spec）。
- **[Trade-off] 一致を検証できるのは `ghostty` タグでビルドしたデーモンとだけ。** 既定のビルド（charmbracelet）とは一致しない部分が残る。→ その差分は D2 の比較用の出力で把握し、既定のビルドを切り替えるかどうかを判断する材料にする（この change の範囲には含めない）。
