# Tabghostty
Libghosttyベースのタブ型ターミナルアプリ

Tabghostty は、[webtabinal](https://github.com/sudabon/webtabinal) のデーモン（Go）につなぐ macOS ネイティブのクライアントです。描画と入力には [libghostty-vt](https://lib.ghostty.org/) を使います。PTY やセッション、エージェント状態の検出、通知の重複排除はデーモン側が担当するので、ブラウザ版と同じセッションを同時に開けます。

アプリに同梱するデーモンは、webtabinal から `daemon/` に取り込んだコピーからビルドします（Phase 6）。同梱版は、画面モデルに Tabghostty と同じ libghostty-vt を使い、出力をバイナリフレームで送ります。取り込み元と変更点は [daemon/UPSTREAM.md](daemon/UPSTREAM.md) にあります。webtabinal のリポジトリは変更しません。

実装の方針は [SPEC.md](SPEC.md) に、各フェーズの変更計画は `openspec/changes/` にあります。

## 開発環境

### 必要なもの

- macOS 14 以降
- Xcode Command Line Tools（Swift 6。Xcode 本体は不要）
- [minisign](https://jedisct1.github.io/minisign/)（libghostty-vt の署名検証に使います）: `brew install minisign`
- Go（`go.mod` の版。`daemon/` のデーモンをビルドするときに必要）
- Node.js と webtabinal のチェックアウト（任意。`make app` で、ブラウザ版の画面をデーモンに埋め込むときだけ必要）

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
make app                                          # daemon/ をビルドして同梱し、build/Tabghostty.app を作る
WEBTABINAL_DIR=~/src/webtabinal make app          # ブラウザ版の画面をビルドする webtabinal の場所を指定する
WEBTABINAL_DAEMON=/path/to/webtabinal make app    # ビルド済みのデーモンを同梱する（daemon/ はビルドしない）
open build/Tabghostty.app
```

- `build/Tabghostty.app/Contents/MacOS/webtabinal-daemon` に、`daemon/` のデーモンを同梱します。起動したときにデーモンが動いていなければ、これを `webtabinal-daemon serve` として起動します（アプリを終了してもデーモンは残ります）。ログは `~/Library/Logs/WebTabinal/daemon.stdio.log` に追記されます。
- デーモンの取得元は、次の順に決まります。
  - `WEBTABINAL_DAEMON`: ビルド済みのデーモンのパス。指定すると `daemon/` はビルドしません。
  - 指定が無ければ、`make daemon` で `daemon/` を `ghostty` タグでビルドします（libghostty-vt を静的にリンクします）。
- ブラウザ版の画面は、`WEBTABINAL_DIR`（既定は `../webtabinal`）の `web/` を `npm run build` して埋め込みます。webtabinal で生成されるのは、gitignore 済みの `web/dist` だけです。チェックアウトが無ければ、警告を出してプレースホルダの画面を埋め込みます（ネイティブ版は動きます）。
- 同梱したデーモンの出どころは、`Info.plist` の `TabghosttyDaemonRevision` に記録されます（`tabghostty-<コミット>`。`daemon/` に未コミットの変更があれば `-dirty`。ビルド済みのデーモンを使ったときは `prebuilt`）。
- バンドル ID は `com.tabghostty.app` で、WebTabinal.app（`com.webtabinal.app`）とは別のアプリとして同時に動かせます。
- 署名は ad-hoc です。
- すでに別のデーモン（たとえば WebTabinal.app が起動したもの）が動いていれば、それにつなぎます。同梱したデーモンに入れ替えたいときは、先に `pkill -f 'webtabinal-daemon serve'` で止めてください（セッションも終了します）。
- macOS の通知（コマンドの完了、エージェントの待ち）は `.app` として起動したときだけ出ます（`UNUserNotificationCenter` の制約）。`swift run` では通知は無効になり、設定画面の「通知」には「この環境ではシステム通知を利用できません」と出ます（未読ドットと Dock のバッジは付きます）。通知の動作は `make app` で作った `.app` で確かめてください。
- 通知の許可は、設定画面（Command-, またはサイドバーの「設定」）の「通知」にある「通知を許可」から求めます。自動では求めません。
- ブラウザ版と Tabghostty の両方で通知を許可していると、同じイベントで通知が 2 回出ます。Tabghostty を使うときは、ブラウザ版の通知を無効にしてください。

### `swift run` で動かす

`.app` にしないで動かすときは、デーモンの場所を `TABGHOSTTY_DAEMON_PATH` で指定します（デーモンがすでに動いていれば不要です）。

```bash
make daemon
TABGHOSTTY_DAEMON_PATH=daemon/bin/webtabinal swift run Tabghostty
```

### 描画と計測の環境変数

| 変数 | 値 | 内容 |
|---|---|---|
| `TABGHOSTTY_RENDERER` | `metal`（既定）/ `coretext` | 端末の描画の実装。Metal のシェーダーは起動時にコンパイルし（Xcode は不要）、終わるまでとコンパイルに失敗したときは Core Text で描きます。比較やデバッグには `coretext` を使います |
| `TABGHOSTTY_LATENCY_LOG` | `1` | キーを押してから、そのエコーを画面に出すまでの時間をログに出します（50 回ごとに中央値・95 パーセンタイル・最大）。手順は [docs/performance.md](docs/performance.md) |

描画のログは `log stream --predicate 'subsystem == "Tabghostty"'` で見られます（category は `render` と `latency`）。

### フィクスチャ（`make fixtures`）

`Tests/Fixtures/agents/` は、`daemon/tests/fixtures/agents`（もとは webtabinal）のコピーです（エージェントの出力を記録したストリーム）。テストはコミット済みのコピーを使うので、テストの実行に webtabinal は要りません。

各フィクスチャの `screen.txt` は、同梱のデーモンの画面モデル（libghostty-vt）が作った最終画面です。`EngineParityTests` は、Tabghostty のエンジンが同じ画面を作ることを確かめます（`screen.txt` の無いフィクスチャは skip します）。

```bash
make screens                                      # daemon/ で screen.txt を作り直し、取り込む
make fixtures                                     # daemon/ から取り込み直す
FIXTURES_SOURCE_DIR=~/src/webtabinal make fixtures  # ほかのチェックアウトから取り込む
```

コピー元のリビジョンと `screen.txt` の件数は `Tests/Fixtures/SOURCE` に記録されます。

### 同梱するデーモン（`daemon/`）

```bash
make daemon        # daemon/bin/webtabinal を ghostty タグでビルドする
make daemon-test   # 既定のビルド（純 Go）と、ghostty タグ（-race 付き）でテストする
```

- cgo には、pkg-config の代わりに `daemon/scripts/pkg-config` で `Vendor/GhosttyVt.xcframework` を渡します（pkg-config も Zig も要りません。先に `make deps`）。
- webtabinal 本体の修正を取り込む手順は [daemon/UPSTREAM.md](daemon/UPSTREAM.md) にあります。

### libghostty-vt のバージョンを上げるとき

1. `scripts/libghostty.lock` の `LIBGHOSTTY_VERSION` を変え、`LIBGHOSTTY_SHA256` を空にする。
2. `bash scripts/fetch-libghostty.sh --pin` を実行する。署名を検証した `SHA256SUMS` から、SHA-256 が lock に書き込まれます。
3. `make deps && make test` を実行し、`Sources/TerminalCore/README.md` の C API 対応表を新しいヘッダに合わせて見直す。
4. 同梱のデーモンも同じ XCFramework にリンクするので、`make daemon-test` と `make screens` を実行する（`screen.txt` に記録したバージョンが変わる）。そのあと `make test` で一致検証を通す。

### C API

libghostty-vt の C 関数・型と、SPEC.md §3 の概念との対応は [Sources/TerminalCore/README.md](Sources/TerminalCore/README.md) にまとめています。実装では、この表にある名前だけを使います。
