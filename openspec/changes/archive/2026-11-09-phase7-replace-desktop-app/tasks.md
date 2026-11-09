# Tasks

> 前提: `phase5-quality-performance` が完了し、archive 済みであること（Phase 6 は任意）。グループ 4 は、利用者の環境での移行の作業。webtabinal のリポジトリは変更しない（Phase 6 の方針。design D4）。

## 1. アイコンと About パネル（spec: app-shell）

- [x] 1.1 webtabinal の `desktop/scripts/generate-icon.swift` を `scripts/generate-icon.swift` に移植し、`Resources/icon.svg`（初期値は webtabinal の `web/public/icon.svg`）から `AppIcon.icns` を作るようにする。CLT だけの環境で `.icns` が生成されることを確認する
  - 確認済み（2026-11-09）: Xcode 本体の無い環境（`xcode-select -p` が `/Library/Developer/CommandLineTools`）で、`swift scripts/generate-icon.swift Resources/icon.svg <out>.icns` が 16〜512 pt の @1x / @2x（10 枚、最大 1024 px）を含む `.icns` を作る。移植元と同じく ImageIO で `.icns` に直接書き出すので、design D2 にある PNG と `iconutil` を経由する手順は使っていない（`iconutil -c iconset` で中身を確認した）
- [x] 1.2 `build-app.sh` で `Contents/Resources/AppIcon.icns` を置き、`CFBundleIconFile` を設定する。`open build/Tabghostty.app` で、Dock にアイコンが出ることを確認する（要手動確認）
  - 実装済み（2026-11-09）: `make app` で `Contents/Resources/AppIcon.icns` が置かれ、`Info.plist` の `CFBundleIconFile` が `AppIcon` になる。アイコンは署名の前に作るので、`codesign --verify --deep --strict` も通る。元画像が無いときや、作れなかったときは、ビルドを止める。Dock の表示も手動確認 OK（2026-11-09）
- [x] 1.3 About パネルにバージョンと `TabghosttyDaemonRevision` を出す。About を開いて、両方が表示されることを確認する（要手動確認）
  - 実装済み（2026-11-09）: アプリメニューの「About Tabghostty」は `AppDelegate.showAboutPanel` に送り、`AboutPanel.options(info:)` の値で `orderFrontStandardAboutPanel(options:)` を出す（`.applicationVersion` に `CFBundleShortVersionString`、`.credits` に `Bundled daemon: <TabghosttyDaemonRevision>`）。Info.plist に値が無い（`swift run`）ときは、バージョンを AppKit の既定に任せ、デーモンは `none` と出す。接続する前でも開けることと、値の組み立ては `AboutPanelTests` で確認済み。About の表示も手動確認 OK（2026-11-09）

## 2. インストール（spec: build-system）

- [x] 2.1 `make install` を実装する（ビルド → `quit app "Tabghostty"` → `/Applications/Tabghostty.app` を置き換え → デーモンの再起動手順を表示。デーモンは止めない）。起動中に実行しても、セッションが残り、置き換えた後に起動すると同じセッションが見えることを確認する（要手動確認）
  - 実装済み（2026-11-09）: `make install` は `make app` のあと `scripts/install-app.sh` を実行する。起動中の Tabghostty はバンドル ID（`com.tabghostty.app`）で探して `osascript` で終了させ（`build/` から起動したものも対象。15 秒待っても終わらなければ、置き換えずに止める）、同じディレクトリにコピーしてから入れ替える。置き換える先は `TABGHOSTTY_INSTALL_DIR`（既定は `/Applications`）で変えられる。最後に、バージョンと同梱のデーモン、`pkill -f 'webtabinal-daemon serve'` の手順を表示する。デーモンには触れない。作業用のディレクトリへの初回のインストールと置き換え、置き換えた後も署名が有効なこと、置き換える先が無いときに止まることは確認済み。起動中に実行したときの動作（`osascript` で終了させるとき、ターミナルに Automation の許可を求められることがある）も手動確認 OK（2026-11-09）

## 3. README

- [x] 3.1 README を design D5 の構成で書き直し、各節の手順をそのとおりに実行して動くことを確認する（要手動確認）。各節の主な内容は次のとおり
  - 必要なもの（Phase 0 の結果、Zig が必要かどうかを含む）
  - クイックスタート
  - 更新の手順（セッションが失われることを明記する）
  - WebTabinal.app からの移行（config とセッションは共有、通知の許可を取り直す、ブラウザ版の通知を無効にすることを推奨）
  - Web 版との違い
  - 画像プロトコル
  - 既知の制約
  - 実装済み（2026-11-09）: design D5 の 10 節で書き直した（開発の節は、これまでの内容に `make install`、アイコン、環境変数の一覧を足した）。「Web 版との違い」は webtabinal `6dca08f` の実装で確かめた（リンクは `WebLinksAddon` でクリックだけで開く、検索の addon は無い、未読の数は Badging API で PWA のときだけ出る、閉じたタブも選ぶまで未読に残る）。手順のうち、`make deps`、`make app`、`make install`（置き換える先を作業用のディレクトリにしたもの）は実行して確認済み。デーモンを止める手順（セッションが失われる）、`/Applications` への置き換え、WebTabinal.app からの移行の手順も手動確認 OK（2026-11-09）
- [x] 3.2 SPEC.md の冒頭に、「この指示書は `webtabinal/native/` を前提に書かれている。Tabghostty では、リポジトリ直下に読み替え、デーモンは webtabinal に残す構成で実装した」という注記を追加する。注記があることを確認する
  - 確認済み（2026-11-09）: SPEC.md の冒頭（ヘッダの箇条書きの直後）に注記を追加した。指定の文言のあとに、Phase 6 でデーモンを `daemon/` に取り込んで同梱する構成に変えたこと（webtabinal は変更しない）を書き添えた。指定の文言だけでは、今の構成と食い違うため

## 4. WebTabinal.app からの移行（webtabinal は変更しない）

- [x] 4.1 webtabinal のリポジトリを変更していないことを確認する（design D4）。`git -C ../webtabinal status` に変更が無く、HEAD が取り込み元の `6dca08f` のままであること
  - 確認済み（2026-11-09）: HEAD は `6dca08f`、`git status --porcelain` は空（`make app` が作る `web/dist` は gitignore 済み）。当初の 4.1（webtabinal で `retire-desktop-shell` を起票し、`desktop/` などを削除する）は、Phase 6 の「webtabinal は変更しない」方針と食い違うので、取りやめた（design D4 の「採用しなかった案」）
- [x] 4.2 `/Applications/WebTabinal.app` を削除し、Tabghostty.app だけで日常的に使えることを確認する（要手動確認）
