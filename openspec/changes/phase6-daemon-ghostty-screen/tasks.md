# Tasks

> 前提: `phase5-quality-performance` が完了し、archive 済みであること。この Phase は任意である。
>
> 1 と 3 は webtabinal リポジトリでの作業で、その完了を Tabghostty 側で記録する。

## 1. webtabinal 側の change を起票する

- [ ] 1.1 webtabinal リポジトリで OpenSpec change を起票する（例: `ghostty-vtscreen-and-binary-frames`）。中身は design.md の D1〜D3 で、対象の spec は `vt-screen-model` と `transport-api`。起票した change の名前を design.md に追記し、webtabinal 側で `openspec validate --strict` が通ることを確認する

## 2. Tabghostty 側: バイナリフレームの受信（spec: daemon-connection）

- [ ] 2.1 `WSConnection` が `.data` のメッセージを受け取れるようにし、D3 の形式（webtabinal 側の change で確定したもの）をデコードして `SessionFrame` に変換する。あわせて、`attach` に `binary: true` を付ける。モック WS で「JSON だけ」「バイナリだけ」「両方が混ざる」の 3 通りで、同じ画面になること、replay を最後まで受け取ると live に移ることをテストで確認する
- [ ] 2.2 今のデーモン（バイナリフレームに対応していない webtabinal `6dca08f` 相当）に接続しても、これまでどおり動くことを確認する（要手動確認）

## 3. webtabinal 側の実装（webtabinal の change で行う）

- [ ] 3.1 webtabinal 側の change を実装して archive する。完了の条件は次の 3 つ
  - `go test -race -tags ghostty ./internal/vtscreen/... ./internal/agentdetect/... ./internal/session/...` が通る
  - 既定のビルドで `go test ./...` が通る
  - `-update-screens` で `screen.txt` と `screen.meta.json` が生成される

  マージしたときの webtabinal のコミットを、design.md に記録する
- [ ] 3.2 バイナリフレームに対応したデーモンで Tabghostty を動かし、Phase 5 の 50 MB 計測をもう一度行う。結果を `docs/performance.md` に追記する（要手動確認）

## 4. Tabghostty 側: エンジンの一致検証（spec: engine-parity）

- [ ] 4.1 `scripts/sync-fixtures.sh` で、`screen.txt` と `screen.meta.json` もコピーするようにする。`make fixtures` を実行して、`Tests/Fixtures` に取り込まれたことを確認する
- [ ] 4.2 `ScreenNormalizer` を作る（表示中の行だけ、末尾の空白を削る、継続セルを飛ばす、結合文字を前の文字に付ける）。日本語の wide 文字、結合文字、末尾の空白のケースをテストで確認する
- [ ] 4.3 一致検証のテストを作る。手順は「バージョンを照合する → フィクスチャを流す → `screen.txt` と比べる」で、`screen.txt` が無ければ skip する。全フィクスチャで一致することを `make test` で確認する。一致しないものがあれば原因を調べ、両方のリポジトリのどちらで直すかを design.md に記録する

## 5. Snapshot を使った replay の検討

- [ ] 5.1 `docs/adr/0001-snapshot-replay.md` を書く。D6 の比較項目について、Snapshot の大きさとエンコードにかかる時間を実測し、採用するかどうかの結論を出す。ADR がリポジトリにあり、結論の節が埋まっていることを確認する
