# Proposal: Phase 7 — WebTabinal.app から Tabghostty.app への置き換え

## Why

Phase 4 以降、Tabghostty.app は現行の WebTabinal.app（WKWebView 版）と同じ機能を持ち、日常的に使えることも確認している。しかし、2 つの課題が残っている。

- 両方のアプリが残ったままなので、どちらを使えばよいのか、どちらを更新すればよいのかが分かりにくい。
- Tabghostty には、インストールや更新の手順、既知の制約が文書化されていない。

SPEC.md §7 Phase 7 は、デスクトップの入口をネイティブ版に一本化し、README を更新することを求めている。

## What Changes

**Tabghostty 側:**

- **`make install`**
  - 起動中の Tabghostty を終了してから、`build/Tabghostty.app` を `/Applications/Tabghostty.app` に置き換える。
  - デーモンは止めない（止めるとシェルのセッションが失われるため）。置き換えた後、更新の手順を案内する。
- **アプリアイコン**
  - webtabinal の `desktop/scripts/generate-icon.swift` を移植し、`Resources/icon.svg` から `AppIcon.icns` を作って同梱する。
  - アイコンの元画像は、ひとまず webtabinal の `web/public/icon.svg` を使う。差し替えやすいように、元画像はファイルとして分けておく。
- **About パネル**
  - Tabghostty のバージョンと、同梱しているデーモンのリビジョン（`TabghosttyDaemonRevision`）を表示する。更新したときに、古いデーモンが残っていないかを切り分けるため。
- **README の整備**: 次の内容を書く。
  - インストール（必要なもの: CLT、Go と Node（デーモンのビルド用）、Zig（Phase 0 の結果、必要な場合））
  - クイックスタート
  - 更新の手順（アプリの終了、古いデーモンの停止、置き換え）
  - WebTabinal.app からの移行（config とセッションは共有されること、通知の許可を取り直すこと、ブラウザ版の通知と重複すること）
  - 画像プロトコル（Kitty Graphics のみ。Sixel と iTerm2 IIP は非対応）
  - Web 版との違い（リンクは Cmd+クリックで開く、Cmd+F で検索、Dock バッジ、閉じたタブを未読から取り除く）
  - 既知の制約（複数のクライアントの重複応答、サイズの取り合い、replay の境界、設定の反映のタイミング）

**webtabinal 側**（design.md に変更案を書き、webtabinal で別の change として実施する）:

- `desktop/` と、`make desktop` / `desktop-test` を削除する。
- README のクイックスタート、「デスクトップアプリの更新」、「画像プロトコル」で、デスクトップの入口として Tabghostty を案内する。ブラウザ版の画像プロトコルの記述（Sixel / IIP 対応）は残す。
- webtabinal の `openspec/specs/desktop-shell` を REMOVED にする。移行先は Tabghostty とする。

## Capabilities

### New Capabilities

（なし）

### Modified Capabilities

Phase 5 の change を先に archive しておくこと。Phase 6 は任意なので、完了している必要はない。

- `build-system`: インストールのコマンドを追加する。
- `app-shell`: アプリアイコンと、About パネルにバージョンを表示することを追加する。

## Impact

- **Tabghostty**
  - `Makefile`（`install`）
  - `scripts/build-app.sh`（アイコン）
  - `scripts/generate-icon.swift`
  - `Resources/icon.svg`
  - About パネル
  - `README.md`
- **webtabinal**
  - `desktop/` の削除
  - `Makefile`
  - `README.md`
  - `openspec/specs/desktop-shell`（REMOVED）
  - これらは webtabinal 側の change で扱う。
- 利用者への影響: WebTabinal.app を使っていた人は、Tabghostty.app に移ることになる。バンドル ID が変わるので、通知の許可を取り直す必要がある。config、セッション、ブラウザ版はそのまま使える。
