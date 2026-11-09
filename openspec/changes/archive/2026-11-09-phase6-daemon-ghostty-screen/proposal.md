# Proposal: Phase 6（任意）— デーモン側の libghostty-vt 化と転送の強化

## Why

Phase 5 の時点では、画面を解釈するエンジンがデーモンとクライアントで異なる。

- デーモン: 画面モデル（`internal/vtscreen`）は charmbracelet/x/vt を使っている。エージェントの状態検出はこの画面を入力にしている。
- Tabghostty: libghostty-vt で表示している。

エンジンが違うと、エージェントの状態検出が見ている画面と、利用者に見えている画面がずれることがある。SPEC.md §7 Phase 6 は、両者を同じエンジンにして、このずれを無くすことを目的にしている。

あわせて、Phase 5 から移した WebSocket のバイナリフレーム化もここで扱う。目的は、JSON と base64 にかかるオーバーヘッドを無くすこと。

この Phase は**任意**である。着手するかどうかは、Phase 5 の計測結果と、日常的に使ってみた感触で決める。

## What Changes

**方針の変更（2026-11-09）**: 当初は、デーモンの変更を webtabinal リポジトリの change として実装する予定だった。しかし、webtabinal は変更しないことになった。そこで、デーモンの Go のコードを Tabghostty の `daemon/` に取り込み、その中で変更する。Tabghostty.app に同梱するデーモンは、この取り込んだコピーからビルドする。webtabinal のソースは変更しない。

- **デーモンの取り込み**（`daemon/`）
  - webtabinal `6dca08f` の `go.mod`、`go.sum`、`cmd/`、`internal/`、`tests/fixtures/agents/` をコピーする。
  - 取り込み元のコミットと、Tabghostty で加えた変更を `daemon/UPSTREAM.md` に記録する。
  - Web 版の画面（`web/`）は取り込まない。`make app` で、これまでどおり `../webtabinal` の Web 版をビルドし、その成果物をデーモンに埋め込む。
- **libghostty-vt 版の画面モデル**（`daemon/internal/vtscreen/ghostty.go`）
  - ビルドタグ `ghostty` を付けたときだけ有効にする。
  - `Screen` インタフェースを `go.mitchellh.com/libghostty` で実装する。
  - リンクする libghostty-vt は、Tabghostty が使っている `Vendor/GhosttyVt.xcframework`（1.0.0）。pkg-config の代わりの小さなスクリプトで渡すので、zig と pkg-config は要らない。
  - タグを付けない既定のビルドは、これまでどおり純 Go のまま。`make app` は `ghostty` タグでビルドする。
- **フィクスチャの最終画面を書き出す仕組み**
  - テスト用のフラグ `-update-screens` で、各フィクスチャに `screen.txt` と `screen.meta.json` を生成する。
- **バイナリフレーム**
  - クライアントが `attach` で `binary: true` を宣言した sid についてだけ、`output` / `replay` をバイナリのメッセージで送る。
- **Tabghostty 側: バイナリフレームの受信**
  - `attach` に `binary: true` を付け、バイナリのメッセージを解釈する。
  - 宣言を無視するデーモン（webtabinal 本体や古い Tabghostty の同梱版）は JSON で送ってくるので、両方を受け付ける。
- **Tabghostty 側: エンジンの一致検証**
  - `daemon/` が生成した `screen.txt` をフィクスチャとして取り込む。
  - Tabghostty のエンジンで最終画面を作り、`screen.txt` と比べるテストを追加する（SPEC §8.1 の「フィクスチャ replay」）。
- **Snapshot を使った replay の検討**
  - Terminal Snapshot で replay する方式を検討した結果を記録する。今の replay は、リングバッファのバイト列を境界を考えずに送るので、壊れたシーケンスから始まることがある。Snapshot は、それを根本から解消できる方式である。
  - 結果は `docs/adr/0001-snapshot-replay.md` に書く。実装は、この change の範囲に含めない。

## Capabilities

### New Capabilities

- `bundled-daemon`: Tabghostty が同梱するデーモン（`daemon/`）の、libghostty-vt 版の画面モデル、バイナリフレームの形式、最終画面の生成。
- `engine-parity`: Tabghostty のエンジンとデーモンの画面モデルで、表示が一致することを検証する。

### Modified Capabilities

Phase 5 の change を先に archive しておくこと。

- `daemon-connection`: バイナリの出力フレームを受信できるようにする。デーモンが対応していない場合は、JSON で受信する。

## Impact

- **Tabghostty**
  - `daemon/`（新規。Go のモジュール。非テスト約 9,000 行、テスト約 11,000 行、フィクスチャ）
  - `DaemonClient` の `WSConnection`
  - `TerminalCore`（`ScreenNormalizer`）と `TerminalCoreTests`
  - `Tests/Fixtures`、`scripts/sync-fixtures.sh`（取り込み元を `daemon/` にする）
  - `scripts/build-app.sh` と `Makefile`（同梱するデーモンを `daemon/` から `ghostty` タグでビルドする）
  - `docs/adr/`
- **webtabinal**: 変更しない。`make app` は、Web 版の画面をビルドするためだけに `../webtabinal` を使う。
- **保守**: webtabinal 本体の修正（エージェントの検出など）は、自動では Tabghostty の同梱版に入らない。取り込むときは `daemon/UPSTREAM.md` の手順に従う。
- **互換性**
  - バイナリフレームは、クライアントが宣言したときだけ使われる。ブラウザ版は影響を受けない。
  - 同梱のデーモンは、webtabinal 本体のデーモンと同じ設定ファイルとプロトコルを使う。
- **依存**
  - 同梱のデーモンをビルドするには、cgo と `Vendor/GhosttyVt.xcframework`（`make deps`）が必要になる。
  - 既定のビルド（タグなし）には、これらは要らない。
