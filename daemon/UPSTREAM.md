# daemon/ の取り込み元と、Tabghostty で加えた変更

`daemon/` は、Tabghostty.app に同梱するデーモン（`webtabinal-daemon`）の Go のモジュールである。webtabinal から取り込み、Tabghostty の中で変更している（`openspec/changes/phase6-daemon-ghostty-screen` の design D0）。webtabinal のリポジトリは変更しない。

## 取り込み元

| 項目 | 値 |
|---|---|
| リポジトリ | https://github.com/sudabon/webtabinal |
| コミット | `6dca08f351aecef2923a494b850981deaf5a45a1`（2026-11-06） |
| 取り込んだ日 | 2026-11-09 |
| コピーした範囲 | `go.mod`、`go.sum`、`LICENSE`、`cmd/`、`internal/`、`tests/fixtures/agents/`、`scripts/record-agent-fixture.sh`（`internal/agentfixtures` のテストが実行する） |
| コピーしていないもの | `web/`（Web 版の画面。`make app` で `../webtabinal` からビルドして埋め込む）、`desktop/`、そのほかの `scripts/`、`openspec/`、`docs/`、`Makefile` |

コピーには `git archive` を使い、追跡されているファイルだけを取り込んだ。

```sh
git -C ../webtabinal archive <commit> go.mod go.sum LICENSE cmd internal tests/fixtures/agents scripts/record-agent-fixture.sh | tar -x -C daemon
```

モジュールのパスは `github.com/sudabon/webtabinal` のまま変えていない（import を書き換えないため）。

## Tabghostty で加えた変更

取り込み直すときは、この一覧の変更を当て直す。新しいファイルは、そのまま残せばよい。

### 追加したファイル

| ファイル | 内容 |
|---|---|
| `.gitignore` | ビルド成果物と、埋め込む Web 版の画面を除く |
| `UPSTREAM.md` | このファイル |
| `scripts/pkg-config` | cgo に `Vendor/GhosttyVt.xcframework` を渡す pkg-config の代わり（design D1） |
| `internal/vtscreen/ghostty.go`、`ghostty_test.go` | libghostty-vt 版の画面モデル（`//go:build ghostty`。design D1） |
| `internal/vtscreen/open_charm.go` | 既定のビルド（`//go:build !ghostty`）の `Open`、`ModelName`、`LibraryVersion` |
| `internal/agentdetect/screens_test.go` | `-update-screens`（フィクスチャの最終画面。design D2） |
| `internal/server/ws_binary.go`、`ws_binary_test.go` | バイナリフレーム（design D3） |
| `internal/server/testdata/binary_frames.json` | バイナリフレームの基準のバイト列（Go と Swift のテストが同じものを読む） |
| `internal/server/contract_test.go`、`testdata/probe_unauthorized.http` | トークン無しの `GET /api/config` への応答の記録（Swift のプローブのテストが、これをデーモンだと認めるかを確かめる） |
| `tests/fixtures/agents/**/screen.txt`、`screen.meta.json` | `make screens` が生成する最終画面（取り込み直した後は `make screens` で作り直す） |

### 変更したファイル

Go のファイルで変更した箇所には、`Tabghostty` と書いたコメントを付けている（`grep -rn Tabghostty --include=*.go .` で探せる）。

| ファイル | 変更 |
|---|---|
| `go.mod`、`go.sum` | `go.mitchellh.com/libghostty v0.0.0-20261107144202-b13f277ddcb2` を追加する |
| `internal/vtscreen/adapter.go` | `Open` を `openCharm` に改名する（ビルドタグで `Open` を選ぶため） |
| `internal/vtscreen/adapter_test.go` | charmbracelet の内部を調べる 2 つのテストを、ghostty のビルドでは skip する |
| `internal/server/ws.go` | `clientMsg.Binary`、`wsClient.binary`、attach での記録、replay と output と attach 中の出力のバイナリ送信（replay は 1 MiB ずつ。replay と attach 中の出力は、送信キューが半分まで空くのを待ってから積む）、`send` から `sendBytes` を分ける、`writeClient` でメッセージの種類を選ぶ |

## 取り込み元から引き継いだ既知の問題

- 既定のビルド（charmbracelet）で `go test -race` を実行すると、`internal/vtscreen` と、セッションを作る `internal/server` のテストが data race で失敗する。
  - 取り込み元の `6dca08f` でも同じように失敗する。
  - 原因は、charmbracelet/x/vt の `Emulator.Close` と、`drainEmulatorReplies` の `Emulator.Read` の競合である。
  - そのため、`make daemon-test` は既定のビルドを `-race` なしで実行する。ghostty のビルドは `-race` 付きで実行し、通っている。同梱するデーモンは ghostty のビルドなので、この競合の影響を受けない。

## webtabinal 本体の修正を取り込む手順

1. webtabinal で、取り込みたいコミットを決める。
2. `daemon/` を作り直す。
   1. 上の「追加したファイル」を退避する。
   2. `daemon/` の中身を消し、上のコマンドでコピーし直す。
   3. 退避したファイルを戻す。
3. 「変更したファイル」の変更を当て直す（`git diff <取り込み前のコミット> -- daemon/<ファイル>` で、以前の変更を確かめられる）。
4. この表の「コミット」と「取り込んだ日」を更新する。
5. 次を実行して確認する。
   - `make daemon-test`
     - `TestUnauthorizedProbeResponseMatchesTheRecordedContract` が失敗したら（トークン無しの応答が変わった）、
       `cd daemon && go test ./internal/server -run TestUnauthorizedProbeResponseMatchesTheRecordedContract -update-contract` で記録し直す。
       その後の `make test` で、プローブがまだ同梱のデーモンを認めるかが分かる。
   - `make screens` と `make fixtures` を実行してから、`make test`（一致検証）
