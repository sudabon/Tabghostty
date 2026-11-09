# Tasks

> 前提: `phase5-quality-performance` が完了し、archive 済みであること（Phase 6 は任意）。グループ 4 は webtabinal リポジトリでの作業で、その完了を Tabghostty 側で記録する。

## 1. アイコンと About パネル（spec: app-shell）

- [ ] 1.1 webtabinal の `desktop/scripts/generate-icon.swift` を `scripts/generate-icon.swift` に移植し、`Resources/icon.svg`（初期値は webtabinal の `web/public/icon.svg`）から `AppIcon.icns` を作るようにする。CLT だけの環境で `.icns` が生成されることを確認する
- [ ] 1.2 `build-app.sh` で `Contents/Resources/AppIcon.icns` を置き、`CFBundleIconFile` を設定する。`open build/Tabghostty.app` で、Dock にアイコンが出ることを確認する（要手動確認）
- [ ] 1.3 About パネルにバージョンと `TabghosttyDaemonRevision` を出す。About を開いて、両方が表示されることを確認する（要手動確認）

## 2. インストール（spec: build-system）

- [ ] 2.1 `make install` を実装する（ビルド → `quit app "Tabghostty"` → `/Applications/Tabghostty.app` を置き換え → デーモンの再起動手順を表示。デーモンは止めない）。起動中に実行しても、セッションが残り、置き換えた後に起動すると同じセッションが見えることを確認する（要手動確認）

## 3. README

- [ ] 3.1 README を design D5 の構成で書き直し、各節の手順をそのとおりに実行して動くことを確認する（要手動確認）。各節の主な内容は次のとおり
  - 必要なもの（Phase 0 の結果、Zig が必要かどうかを含む）
  - クイックスタート
  - 更新の手順（セッションが失われることを明記する）
  - WebTabinal.app からの移行（config とセッションは共有、通知の許可を取り直す、ブラウザ版の通知を無効にすることを推奨）
  - Web 版との違い
  - 画像プロトコル
  - 既知の制約
- [ ] 3.2 SPEC.md の冒頭に、「この指示書は `webtabinal/native/` を前提に書かれている。Tabghostty では、リポジトリ直下に読み替え、デーモンは webtabinal に残す構成で実装した」という注記を追加する。注記があることを確認する

## 4. webtabinal 側の後片付け（webtabinal の change で行う）

- [ ] 4.1 webtabinal リポジトリで OpenSpec change を起票し（例: `retire-desktop-shell`）、design D4 の内容を実施する。中身は次のとおり
  - `desktop/` の削除
  - `Makefile` の `desktop` / `desktop-test` の削除
  - README の更新
  - `desktop-shell` spec の REMOVED

  webtabinal 側で `openspec validate --strict`、`make build`、`go test ./...`、`npm test` が通ることを確認し、マージしたコミットを design.md に記録する
- [ ] 4.2 `/Applications/WebTabinal.app` を削除し、Tabghostty.app だけで日常的に使えることを確認する（要手動確認）
