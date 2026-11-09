# Tasks

> 前提: `phase5-quality-performance` が完了し、archive 済みであること。この Phase は任意である。
>
> 2026-11-09 に方針を変えた。webtabinal は変更せず、デーモンを `daemon/` に取り込んで、その中で変更する（design D0）。

## 1. デーモンを取り込む（design D0）

- [x] 1.1 webtabinal `6dca08f` の `go.mod`、`go.sum`、`cmd/`、`internal/`、`tests/fixtures/agents/`、`LICENSE`、`scripts/record-agent-fixture.sh` を `daemon/` にコピーする。`daemon/UPSTREAM.md` に、取り込み元のコミット、コピーした範囲、取り込み直しの手順を書く。手を加える前の状態で、`daemon/` で `go test ./...` が通ることを確認する

## 2. Tabghostty 側: バイナリフレームの受信（spec: daemon-connection）

- [x] 2.1 `WSConnection` が `.data` のメッセージを受け取れるようにし、D3 の形式をデコードして `ServerFrame` に変換する。あわせて、`attach` に `binary: true` を付ける。モック WS で「JSON だけ」「バイナリだけ」「両方が混ざる」の 3 通りで、同じ画面になること、replay を最後まで受け取ると live に移ることをテストで確認する。Go 側のエンコードと Swift 側のデコードが、同じバイト列で一致することも確認する
- [ ] 2.2 バイナリフレームに対応していないデーモン（webtabinal 本体の `6dca08f` 相当）に接続しても、これまでどおり動くことを確認する（要手動確認）

## 3. 同梱するデーモン（spec: bundled-daemon、build-system）

- [x] 3.1 `daemon/internal/vtscreen/ghostty.go` を作る（D1）。`daemon/scripts/pkg-config` で `Vendor/GhosttyVt.xcframework` にリンクする。`go test -race -tags ghostty ./internal/vtscreen/... ./internal/agentdetect/... ./internal/session/...` と、タグなしの `go test ./...` が通ることを確認する
- [x] 3.2 `-update-screens` で `screen.txt` と `screen.meta.json` を生成するテストを作る（D2）。ghostty タグで、フラグを付けないときは、コミット済みの `screen.txt` が今の出力と同じであることを確かめる。`make screens` で全フィクスチャに生成されることを確認する
- [x] 3.3 `daemon/internal/server/ws.go` で、`attach` の `binary: true` に応じてバイナリフレームを送る（D3）。宣言した場合・しない場合・attach 中にためた出力の 3 つを、Go のテストで確認する
- [x] 3.4 `make daemon`、`make daemon-test`、`make screens` を追加し、`make app` が `daemon/` から ghostty タグでビルドしたデーモンを同梱するようにする（D7）。`make app` を実行して、同梱したデーモンが ghostty の画面モデルで動くこと、webtabinal の追跡しているファイルが変わっていないことを確認する
- [ ] 3.5 同梱したデーモン（バイナリフレーム対応）で Tabghostty を動かし、Phase 5 の 50 MB 計測をもう一度行う。結果を `docs/performance.md` に追記する（要手動確認）

## 4. Tabghostty 側: エンジンの一致検証（spec: engine-parity）

- [x] 4.1 `scripts/sync-fixtures.sh` で、取り込み元を `daemon/` にし、`screen.txt` と `screen.meta.json` もコピーするようにする。`make fixtures` を実行して、`Tests/Fixtures` に取り込まれたことを確認する
- [x] 4.2 `ScreenNormalizer` を作る（表示中の行だけ、末尾の空白を削る、継続セルを飛ばす、結合文字を前の文字に付ける）。日本語の wide 文字、結合文字、末尾の空白のケースをテストで確認する
- [x] 4.3 一致検証のテストを作る。手順は「バージョンを照合する → フィクスチャを流す → `screen.txt` と比べる」で、`screen.txt` が無ければ skip する。全フィクスチャで一致することを `make test` で確認する。一致しないものがあれば原因を調べ、どちら（`daemon/` か Tabghostty）で直すかを design.md に記録する

## 5. Snapshot を使った replay の検討

- [x] 5.1 `docs/adr/0001-snapshot-replay.md` を書く。D6 の比較項目について、Snapshot の大きさとエンコードにかかる時間を実測し、採用するかどうかの結論を出す。ADR がリポジトリにあり、結論の節が埋まっていることを確認する
