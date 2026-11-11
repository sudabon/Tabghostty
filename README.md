# Tabghostty
Libghosttyベースのタブ型ターミナルアプリ

## 概要

Tabghostty は、[webtabinal](https://github.com/sudabon/webtabinal) のデーモン（Go）につなぐ macOS ネイティブのクライアントです。描画と入力には [libghostty-vt](https://lib.ghostty.org/) を使います。

- PTY、セッション、エージェントの状態の検出、通知の重複排除は、デーモンが担当します。そのため、ブラウザ版の webtabinal と同じセッションを同時に開けます。
- 設定（`~/Library/Application Support/WebTabinal/config.json`）も、ブラウザ版と共有します。
- デスクトップアプリとしては、WebTabinal.app（WKWebView 版）を置き換えるものです。移行の手順は「[WebTabinal.app からの移行](#webtabinalapp-からの移行)」にあります。

アプリに同梱するデーモンは、webtabinal から `daemon/` に取り込んだコピーからビルドします。同梱版は、画面モデルに Tabghostty と同じ libghostty-vt を使い、出力をバイナリフレームで送ります。取り込み元と変更点は [daemon/UPSTREAM.md](daemon/UPSTREAM.md) にあります。webtabinal のリポジトリは変更しません。

実装の方針は [SPEC.md](SPEC.md) に、各フェーズの変更計画は `openspec/changes/` にあります。

## 必要なもの

| ツール | 用途 | 備考 |
|---|---|---|
| macOS 14 以降 | 実行環境 | |
| Xcode Command Line Tools | Swift 6 でのビルド、アイコンの生成 | Xcode 本体は不要。`xcode-select --install` |
| [minisign](https://jedisct1.github.io/minisign/) | libghostty-vt の署名の検証（`make deps`） | `brew install minisign` |
| Go | 同梱するデーモン（`daemon/`）のビルド | `daemon/go.mod` の版（現在 1.26.5）以上 |
| Node.js / npm と webtabinal のチェックアウト | ブラウザ版の画面を、同梱するデーモンに埋め込む | 任意。無ければ、ブラウザ版の画面はプレースホルダになります（ネイティブ版は動きます） |

Zig は不要です。libghostty-vt は、公式のビルド済み XCFramework を使います（Phase 0 で確認済み）。

Homebrew を使う場合の例:

```bash
xcode-select --install
brew install minisign go node
```

## クイックスタート

```bash
git clone git@github.com:sudabon/Tabghostty.git
git clone git@github.com:sudabon/webtabinal.git   # 任意: ブラウザ版の画面を埋め込むとき（Tabghostty と同じ階層に置く）
(cd webtabinal/web && npm install)                # 任意: 同上

cd Tabghostty
make deps      # libghostty-vt を取得し、SHA-256 と署名を検証して Vendor/ に置く
make install   # build/Tabghostty.app を作り、/Applications/Tabghostty.app に置く
open /Applications/Tabghostty.app
```

- 起動したときにデーモンが動いていなければ、同梱のデーモンを `webtabinal-daemon serve` として起動します。すでに動いていれば（WebTabinal.app が起動したものを含む）、それにつなぎます。
- 初めて起動したときは、新しいタブが 1 つ開きます。
- ウィンドウを閉じるとアプリは終了しますが、デーモンとセッションは残ります。もう一度起動すると、同じセッションにつながります。
- ウィンドウの位置と大きさは、次の起動で戻ります。
- ブラウザ版は、これまでどおり `http://127.0.0.1:8642` で開けます（同じセッションが見えます）。

## 更新の手順

```bash
cd Tabghostty
git pull
make deps      # scripts/libghostty.lock が変わったときだけ取得し直す（変わっていなければ何もしない）
make install   # 起動中の Tabghostty を終了し、/Applications/Tabghostty.app を置き換える
open /Applications/Tabghostty.app
```

`make install` は、デーモンを止めません。PTY のセッションはデーモンが持っているので、アプリだけを置き換えれば、作業中のシェルはそのまま残ります。起動中の Tabghostty は `osascript` で終了させます（初回は、ターミナルに Automation の許可を求められることがあります）。

ただし、これだけでは、**動いているデーモンは古いまま**です。同梱のデーモンを新しくするには、セッションを閉じてよいときに、デーモンを止めてから Tabghostty を起動し直します。

```bash
pkill -f 'webtabinal-daemon serve'
lsof -nP -iTCP:8642 -sTCP:LISTEN   # 何も出なければ止まっている
open /Applications/Tabghostty.app  # 新しく同梱したデーモンが起動する
```

- **デーモンを止めると、すべてのシェルのセッションが失われます。** エージェント（Claude Code など）のタブは、設定の「一般」で「セッションの復元」が有効なら、デーモンを起動し直したときに戻ります。それ以外のタブは戻りません。
- 動いているデーモンがどのアプリのものかは、`pgrep -fl 'webtabinal-daemon serve'` で、アプリに同梱したデーモンの出どころは、メニューの「About Tabghostty」の「Bundled daemon」（`tabghostty-<コミット>`）で確かめられます。
- webtabinal の LaunchAgent（`webtabinal install`）でデーモンを常駐させている場合は、Tabghostty はそのデーモンにつなぎます。同梱のデーモンに切り替えるときは、先に `webtabinal uninstall` で外してください。

## WebTabinal.app からの移行

Tabghostty と WebTabinal.app は、同じデーモン、同じ config.json、同じセッションを使います。移行しても、設定とセッションはそのまま引き継がれます。

1. 「[クイックスタート](#クイックスタート)」のとおりに、Tabghostty をインストールして起動します。WebTabinal.app が起動したデーモンが動いていれば、Tabghostty はそれにつなぐので、今のタブがそのまま見えます。
2. **通知の許可を取り直します。** バンドル ID が違う（`com.tabghostty.app`。WebTabinal.app は `com.webtabinal.app`）ので、macOS の通知の許可は別になります。設定（Command-,）の「通知」で「通知を許可」を押してください。自動では求めません。
3. **ブラウザ版の通知を無効にすることを推奨します。** ブラウザ版と Tabghostty の両方で通知を許可していると、同じイベントで通知が 2 回出ます。ブラウザのサイトの設定で、`http://127.0.0.1:8642` の通知をオフにしてください。
4. WebTabinal.app を終了し、`/Applications/WebTabinal.app` を削除します。Tabghostty は、青い画面に白いゴーストとタブを描いた専用アイコンで見分けられます。
5. （任意）セッションを閉じてよいときに、WebTabinal.app のデーモンを止めて、同梱のデーモンに切り替えます（手順は「[更新の手順](#更新の手順)」）。WebTabinal.app のデーモンのままでも Tabghostty は動きますが、同梱のデーモンに切り替えると、エージェントの状態の検出に使う画面が Tabghostty の表示と同じエンジンになり、出力の転送も速くなります。

## 使い方

### タブ

- 左のサイドバーに、デーモンのすべてのセッションがタブとして並びます。各タブには、場所、コマンド、実行状態、エージェントの状態（`idle` / `working` / `blocked`）が出ます。
- 「＋ 新規タブ」または Command-N で、ホームディレクトリに新しいタブを開きます。
- タブはドラッグで並べ替えられます。順序はデーモンに保存され、ブラウザ版と共有されます。
- ダブルクリックで、タブのメモ（30 文字まで）を編集できます。メモは、タブにポインタを 1 秒置くと表示されます。
- 右クリックのメニューには「複製」「再起動」（終了したタブだけ）「閉じる」「通知」があります。「通知」のチェックを外すと、そのタブの通知だけを止められます。
- 実行中のタブを閉じるときは、確認を求めます（設定 `confirm_close_running`）。最後のタブを閉じると、アプリは終了します（`quit_when_no_tabs`）。
- サイドバーは、上部のボタン、または View メニューの「サイドバーを表示/隠す」で隠せます。幅は縁をドラッグして 160〜480 pt に変えられます。
- 裏のタブでコマンドが終わったり、エージェントが入力を待ったりすると、タブに未読のドットが付き、Dock のアイコンに未読のタブの数が出ます。

### キーボードショートカット

| キー | 動作 |
|---|---|
| Command-N | 新しいタブ |
| Command-1〜9 | その位置のタブを選ぶ |
| Command-F | 検索バーを開く |
| Command-G / Command-Shift-G | 次 / 前の検索結果 |
| Command-C / Command-V | コピー / ペースト（画像があれば添付） |
| Control-V | そのまま端末に送る（Claude Code や Codex が自分でクリップボードを読む） |
| Shift-Enter | 改行（`ESC CR`。設定 `shift_enter_newline`、既定でオン） |
| Command-, | 設定 |
| Control-J → N / P / J | 次のタブ / 前のタブ / サイドバーの表示・非表示（既定ではオフ。設定の「キーボード」で有効にし、キーを変えられる） |

Control-J（プレフィックス）を押すと、画面の下に `Ctrl+J …` と出て、3 秒間だけ次のキーを待ちます。Escape やほかのキーで取り消せます。どのキーも端末には送りません。

### 検索

Command-F で、表示中のタブの画面とスクロールバックを検索します。大文字と小文字は区別しません。すべての一致を強調し、`3 / 12` のように位置と件数を出します。Enter か Command-G で次へ、Shift-Enter か Command-Shift-G で前へ移り、Escape で閉じます。

### リンク

Command を押しながらリンクにポインタを置くと、下線が付きます。Command-クリックで、既定のブラウザで開きます。開くのは `http` と `https` だけです。OSC 8 のハイパーリンクと、画面に出た URL の両方を認識します。

### 選択とコピー

- ドラッグで選択し、ダブルクリックで単語を、トリプルクリックで行を選択します。プログラムがマウスを使っているときは、Shift を押しながらドラッグします。
- Command-C でコピーします。設定 `copy_on_select` をオンにすると、選択しただけでコピーします。
- プログラムからのクリップボードへの書き込み（OSC 52）は受け付けますが、読み取りは拒否します。

### 画像の添付

Claude Code、Codex、cursor-agent に、画像をファイルのパスとして渡せます。

- スクリーンショットをコピーして Command-V を押すか、画像ファイルを端末にドロップすると、デーモンに保存して、そのパスをプロンプトに入力します。
- 対応する形式は PNG、JPEG、GIF、WebP で、1 枚 10 MiB までです。複数の画像は、スペースで区切って入力します。
- 保存先は `~/Library/Application Support/WebTabinal/images/` です（7 日を過ぎると、デーモンが削除します）。

### 設定

Command-,（またはサイドバーの「設定」）で設定画面を開きます。「外観」「一般」「通知」「キーボード」の 4 つがあり、変えるとすぐに config.json に保存されます。ブラウザ版の設定画面と同じものを編集します。

### 通知

コマンドの完了と、エージェントの入力待ち（blocked など）を、macOS の通知で知らせます。通知をクリックすると、そのタブに移ります。

- 通知は、`.app` として起動したときだけ出ます（`swift run` では出ません）。
- 許可は、設定の「通知」の「通知を許可」から求めます。
- 通知を許可していなくても、未読のドットと Dock のバッジは付きます。

## Web 版との違い

| | Tabghostty | ブラウザ版 / WebTabinal.app |
|---|---|---|
| リンク | Command-クリックで開く（クリックだけでは開かない） | クリックで開く |
| 検索 | Command-F で、スクロールバックを含めて検索できる | なし |
| 未読の数 | Dock のアイコンにバッジで出る | インストールした PWA のときだけ、Badging API で出る |
| 閉じたタブの未読 | 閉じたタブは未読の数から除く | 選ぶまで未読の数に残る（閉じたタブも数える） |
| 画像の表示 | Kitty Graphics だけ（下の「画像プロトコル」） | kitty、Sixel、iTerm2 IIP |
| 端末の機能 | kitty keyboard protocol、同期出力（`?2026`）、ピクセル単位のマウス（`?1016`）に対応 | 非対応 |
| 通知の許可 | Tabghostty で別に取る | ブラウザ / WebTabinal.app ごとに取る |

## 画像プロトコル

Tabghostty が表示するインライン画像は、**kitty graphics protocol だけ**です。Retina でも、セルの大きさに合わせた大きさで表示し、テキストと一緒にスクロールします。

Sixel と iTerm2 inline image（OSC 1337 File）は、libghostty-vt が対応していないので、表示しません。受け取っても、画面が崩れたり、文字のくずが残ったりはしません。これらの形式で画像を表示したいときは、ブラウザ版を使ってください（ブラウザ版は kitty、Sixel、IIP のすべてに対応しています）。

## 既知の制約

- **複数のクライアントの重複応答**: 同じセッションをブラウザ版と Tabghostty で同時に開いていると、端末への問い合わせ（DA や DSR など）に両方が応答します。シェルに余計な文字が入ることがあります。WebTabinal.app のときも同じです。同じタブを両方で同時に操作しないでください。
- **サイズの取り合い**: PTY の大きさは、セッションごとに 1 つです。最後に大きさを送ったクライアントの値になります。Tabghostty は、タブを選んだときとウィンドウの大きさを変えたときに、自分の大きさを送ります。ブラウザ版で大きさを変えたあとは、Tabghostty の表示が、次に描き直されるまで崩れることがあります。
- **replay の境界**: タブを開いたときと再接続したときは、デーモンのリングバッファ（既定 5 MiB）の出力を流し直して画面を作ります。リングバッファは区切りを考えずに古いバイトを捨てるので、最初の行が崩れることがあります。また、リングバッファより前に設定された状態（alternate screen、モード、タイトルなど）は再現されません。検討の結果は [docs/adr/0001-snapshot-replay.md](docs/adr/0001-snapshot-replay.md) にあります。
- **設定の反映のタイミング**: ブラウザ版や config.json で変えた設定は、Tabghostty が前面に来たとき、設定画面を開いたとき、再接続したときに読み直して反映します。裏にあるあいだは反映されません。起動シェルの変更は、新しく開くタブから使われます。
- **配布**: ローカルでビルドし、ad-hoc で署名して使う前提です。署名済みの配布物はありません。

## 開発

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

### アプリを作る（`make app` / `make install`）

```bash
make app                                          # daemon/ をビルドして同梱し、build/Tabghostty.app を作る
WEBTABINAL_DIR=~/src/webtabinal make app          # ブラウザ版の画面をビルドする webtabinal の場所を指定する
WEBTABINAL_DAEMON=/path/to/webtabinal make app    # ビルド済みのデーモンを同梱する（daemon/ はビルドしない）
open build/Tabghostty.app

make install                                      # make app のあと、/Applications/Tabghostty.app に置き換える
TABGHOSTTY_INSTALL_DIR=~/Applications make install  # 置き換える先を変える
```

- `build/Tabghostty.app/Contents/MacOS/webtabinal-daemon` に、`daemon/` のデーモンを同梱します。起動したときにデーモンが動いていなければ、これを `webtabinal-daemon serve` として起動します（アプリを終了してもデーモンは残ります）。ログは `~/Library/Logs/WebTabinal/daemon.stdio.log` に追記されます。
- デーモンの取得元は、次の順に決まります。
  - `WEBTABINAL_DAEMON`: ビルド済みのデーモンのパス。指定すると `daemon/` はビルドしません。
  - 指定が無ければ、`make daemon` で `daemon/` を `ghostty` タグでビルドします（libghostty-vt を静的にリンクします）。
- ブラウザ版の画面は、`WEBTABINAL_DIR`（既定は `../webtabinal`）の `web/` を `npm run build` して埋め込みます。webtabinal で生成されるのは、gitignore 済みの `web/dist` だけです。チェックアウトが無ければ、警告を出してプレースホルダの画面を埋め込みます（ネイティブ版は動きます）。
- 同梱したデーモンの出どころは、`Info.plist` の `TabghosttyDaemonRevision` に記録され、About パネルに出ます（`tabghostty-<コミット>`。`daemon/` に未コミットの変更があれば `-dirty`。ビルド済みのデーモンを使ったときは `prebuilt`）。
- アプリアイコンは、`Resources/icon.svg` から `scripts/generate-icon.swift` で作ります（`Contents/Resources/AppIcon.icns`）。アイコンを変えるときは、この SVG を差し替えます。
- `make install` は、起動中の Tabghostty（`build/` から起動したものも含む）を終了してから置き換えます。デーモンには触れません。
- バンドル ID は `com.tabghostty.app` で、WebTabinal.app（`com.webtabinal.app`）とは別のアプリとして同時に動かせます。
- 署名は ad-hoc です。
- macOS の通知は `.app` として起動したときだけ出ます（`UNUserNotificationCenter` の制約）。`swift run` では通知は無効になり、設定画面の「通知」には「この環境ではシステム通知を利用できません」と出ます（未読ドットと Dock のバッジは付きます）。通知の動作は `make app` で作った `.app` で確かめてください。

### `swift run` で動かす

`.app` にしないで動かすときは、デーモンの場所を `TABGHOSTTY_DAEMON_PATH` で指定します（デーモンがすでに動いていれば不要です）。

```bash
make daemon
TABGHOSTTY_DAEMON_PATH=daemon/bin/webtabinal swift run Tabghostty
```

### 環境変数

| 変数 | 値 | 内容 |
|---|---|---|
| `TABGHOSTTY_RENDERER` | `metal`（既定）/ `coretext` | 端末の描画の実装。Metal のシェーダーは起動時にコンパイルし（Xcode は不要）、終わるまでとコンパイルに失敗したときは Core Text で描きます。比較やデバッグには `coretext` を使います |
| `TABGHOSTTY_LATENCY_LOG` | `1` | キーを押してから、そのエコーを画面に出すまでの時間をログに出します（50 回ごとに中央値・95 パーセンタイル・最大）。手順は [docs/performance.md](docs/performance.md) |
| `TABGHOSTTY_DAEMON_PATH` | パス | `swift run` のときに起動するデーモン |
| `TABGHOSTTY_INSTALL_DIR` | ディレクトリ | `make install` で置き換える先（既定は `/Applications`） |
| `WEBTABINAL_DIR` / `WEBTABINAL_DAEMON` | パス | `make app` で使う webtabinal のチェックアウト / ビルド済みのデーモン |
| `FIXTURES_SOURCE_DIR` | パス | `make fixtures` の取り込み元（既定は `daemon/`） |

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
