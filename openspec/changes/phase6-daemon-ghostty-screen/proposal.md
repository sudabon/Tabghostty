# Proposal: Phase 6（任意）— デーモン側の libghostty-vt 化と転送の強化

## Why

Phase 5 の時点では、画面を解釈するエンジンがデーモンとクライアントで異なる。

- デーモン: 画面モデル（`internal/vtscreen`）は charmbracelet/x/vt を使っている。エージェントの状態検出はこの画面を入力にしている。
- Tabghostty: libghostty-vt で表示している。

エンジンが違うと、エージェントの状態検出が見ている画面と、利用者に見えている画面がずれることがある。SPEC.md §7 Phase 6 は、両者を同じエンジンにして、このずれを無くすことを目的にしている。

あわせて、Phase 5 から移した WebSocket のバイナリフレーム化もここで扱う。目的は、JSON と base64 にかかるオーバーヘッドを無くすこと。

この Phase は**任意**である。着手するかどうかは、Phase 5 の計測結果と、日常的に使ってみた感触で決める。

## What Changes

この change は、2 つのリポジトリにまたがる。デーモン側の実装は webtabinal の OpenSpec change として起票して実装する（Tabghostty をクライアント専用にするという方針に合わせるため）。この change では、Tabghostty 側の実装と、webtabinal 側に渡す変更案を管理する。

**webtabinal 側**（design.md に変更案を書き、webtabinal で別の change として起票する）:

- `internal/vtscreen/ghostty.go`
  - ビルドタグ `ghostty` を付けたときだけ有効にする。
  - `Screen` インタフェースを `go.mitchellh.com/libghostty` で実装する。
  - 既定のビルドは、これまでどおり純 Go のまま。
- フィクスチャの最終画面を書き出す仕組み
  - テスト用の `-update-screens` を使い、各フィクスチャに `screen.txt` を生成する。
- バイナリフレーム
  - クライアントが `attach` で `binary: true` を宣言した sid についてだけ、`output` / `replay` をバイナリのメッセージで送る。

**Tabghostty 側**:

- **バイナリフレームの受信**
  - `attach` に `binary: true` を付け、バイナリのメッセージを解釈する。
  - 古いデーモンは `binary` を無視して JSON で送ってくるので、両方を受け付けて自動的にどちらでも動くようにする。
- **エンジンの一致検証**
  - webtabinal が生成した `screen.txt` をフィクスチャとして取り込む。
  - Tabghostty のエンジンで最終画面を作り、`screen.txt` と比べるテストを追加する（SPEC §8.1 の「フィクスチャ replay」）。
- **Snapshot を使った replay の検討**
  - Terminal Snapshot で replay する方式について、検討した結果を記録する。今の replay は、リングバッファのバイト列を境界を考えずに送るので、壊れたシーケンスから始まることがある。それを根本から解消できる方式である。
  - 結果は `docs/adr/0001-snapshot-replay.md` に書く。実装は、この change の範囲に含めない。

## Capabilities

### New Capabilities

- `engine-parity`: Tabghostty のエンジンとデーモンの画面モデルで、表示が一致することを検証する。

### Modified Capabilities

Phase 5 の change を先に archive しておくこと。

- `daemon-connection`: バイナリの出力フレームを受信できるようにする。デーモンが対応していない場合は、JSON で受信する。

## Impact

- **webtabinal**
  - `internal/vtscreen/`（新しいファイルを追加。ビルドタグで隔離する）
  - `internal/server/ws.go`（`attach` の `binary` と、バイナリの送信）
  - フィクスチャ用のテスト
  - `go.mod`（`go.mitchellh.com/libghostty` をコミットで固定する）
  - これらは webtabinal 側の change で扱う。
- **Tabghostty**
  - `DaemonClient` の `WSConnection`
  - `TerminalCoreTests`
  - `Tests/Fixtures`
  - `scripts/sync-fixtures.sh`
  - `docs/adr/`
- **互換性**: バイナリフレームは、クライアントが宣言したときだけ使われる。そのため、ブラウザ版や古い Tabghostty は影響を受けない。
- **依存**: デーモンを `ghostty` タグでビルドするには、cgo と libghostty が必要になる。既定のビルドには入れない。
