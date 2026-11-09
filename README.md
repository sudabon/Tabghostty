# Tabghostty
Libghosttyベースのタブ型ターミナルアプリ

Tabghostty は、[webtabinal](https://github.com/sudabon/webtabinal) のデーモン（Go）につなぐ macOS ネイティブのクライアントです。描画と入力には [libghostty-vt](https://lib.ghostty.org/) を使います。PTY やセッション、エージェント状態の検出、通知の重複排除はデーモン側が担当するので、ブラウザ版と同じセッションを同時に開けます。

実装の方針は [SPEC.md](SPEC.md) に、各フェーズの変更計画は `openspec/changes/` にあります。

## 開発環境

### 必要なもの

- macOS 14 以降
- Xcode Command Line Tools（Swift 6。Xcode 本体は不要）
- [minisign](https://jedisct1.github.io/minisign/)（libghostty-vt の署名検証に使います）: `brew install minisign`
- webtabinal のデーモン（Phase 1 以降でアプリを動かすときに必要）

libghostty-vt は公式のビルド済み XCFramework を使うので、Zig は不要です。

### セットアップとテスト

```bash
make deps    # libghostty-vt 1.0.0 を取得し、SHA-256 と minisign 署名を検証して Vendor/ に置く
make build   # 全ターゲットをビルドする
make test    # テストを実行する（Swift Testing）
```

- `make deps` は、`scripts/libghostty.lock` に記録したバージョンと SHA-256 で検証します。検証済みのものがすでに置かれていれば、何もしません。
- `make build` / `make test` を `make deps` より前に実行すると、「先に `make deps` を実行してください」と表示して止まります。
- `Vendor/GhosttyVt.xcframework` は git 管理外です。
- `make test-tsan` で、Thread Sanitizer 付きでテストを実行できます（端末への並行アクセスの検査）。

### アプリを作る（`make app`）

```bash
make app                                          # ../webtabinal をビルドして同梱し、build/Tabghostty.app を作る
WEBTABINAL_DIR=~/src/webtabinal make app          # webtabinal のチェックアウトの場所を指定する
WEBTABINAL_DAEMON=/path/to/webtabinal make app    # ビルド済みのデーモンを同梱する（webtabinal はビルドしない）
open build/Tabghostty.app
```

- `build/Tabghostty.app/Contents/MacOS/webtabinal-daemon` に、webtabinal のデーモンを同梱します。起動したときにデーモンが動いていなければ、これを `webtabinal-daemon serve` として起動します（アプリを終了してもデーモンは残ります）。ログは `~/Library/Logs/WebTabinal/daemon.stdio.log` に追記されます。
- デーモンの取得元は、次の順に決まります。
  - `WEBTABINAL_DAEMON`: ビルド済みのデーモンのパス。指定すると webtabinal はビルドしません。
  - `WEBTABINAL_DIR`: webtabinal のチェックアウト（既定は `../webtabinal`）。`make -C "$WEBTABINAL_DIR" build`（Go と Node.js が要ります）を実行し、`bin/webtabinal` を同梱します。
  - どちらも無ければ、2 つの変数名を出して失敗します。
- 同梱した webtabinal のコミットは、`Info.plist` の `TabghosttyDaemonRevision` に記録されます（ビルド済みのデーモンを使ったときは `prebuilt`）。
- バンドル ID は `com.tabghostty.app` で、WebTabinal.app（`com.webtabinal.app`）とは別のアプリとして同時に動かせます。
- 署名は ad-hoc です。
- すでに別のデーモン（たとえば WebTabinal.app が起動したもの）が動いていれば、それにつなぎます。同梱したデーモンに入れ替えたいときは、先に `pkill -f 'webtabinal-daemon serve'` で止めてください（セッションも終了します）。

### `swift run` で動かす

`.app` にしないで動かすときは、デーモンの場所を `TABGHOSTTY_DAEMON_PATH` で指定します（デーモンがすでに動いていれば不要です）。

```bash
TABGHOSTTY_DAEMON_PATH=../webtabinal/bin/webtabinal swift run Tabghostty
```

### フィクスチャ（`make fixtures`）

`Tests/Fixtures/agents/` は、webtabinal の `tests/fixtures/agents` のコピーです（エージェントの出力を記録したストリーム）。テストはコミット済みのコピーを使うので、テストの実行に webtabinal は要りません。

```bash
make fixtures                                     # ../webtabinal から取り込み直す
WEBTABINAL_DIR=~/src/webtabinal make fixtures     # webtabinal の場所を指定する
```

コピー元のコミットは `Tests/Fixtures/SOURCE` に記録されます。

### libghostty-vt のバージョンを上げるとき

1. `scripts/libghostty.lock` の `LIBGHOSTTY_VERSION` を変え、`LIBGHOSTTY_SHA256` を空にする。
2. `bash scripts/fetch-libghostty.sh --pin` を実行する。署名を検証した `SHA256SUMS` から、SHA-256 が lock に書き込まれます。
3. `make deps && make test` を実行し、`Sources/TerminalCore/README.md` の C API 対応表を新しいヘッダに合わせて見直す。

### C API

libghostty-vt の C 関数・型と、SPEC.md §3 の概念との対応は [Sources/TerminalCore/README.md](Sources/TerminalCore/README.md) にまとめています。実装では、この表にある名前だけを使います。
