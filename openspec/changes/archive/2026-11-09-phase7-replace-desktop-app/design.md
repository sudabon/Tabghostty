# Design: Phase 7 — WebTabinal.app から Tabghostty.app への置き換え

## Context

- Phase 6 で、webtabinal のデーモンを `daemon/` に取り込み、そこからビルドしたものを Tabghostty.app に同梱する構成にした。webtabinal のリポジトリは変更しない（2026-11-09 決定）。Web 版の画面は、`make app` で `../webtabinal` からビルドして埋め込む。
- SPEC §7 Phase 7 は、`webtabinal/native/` があることを前提に、次の 3 点を挙げている。
  - `make desktop` をネイティブ版に向ける。
  - `desktop/` を削除する。
  - README の 5 つの節を更新し、Zig を必要なツールに加える。

  本リポジトリの構成に合わせて、この change では Tabghostty 側の整備だけを行う。webtabinal の `desktop/` と README は変更しない（D4）。
- webtabinal の現状（`6dca08f`）:
  - `make desktop` は、`build`、`desktop-test`、`desktop/scripts/build-app.sh` を順に実行し、`bin/WebTabinal.app` を作る。
  - README の「デスクトップアプリの更新」の手順は、アプリの終了 → 古いデーモンを pkill → 8642 番ポートが空いたことを確認 → `make desktop` → `/Applications` に置き換え。
  - アイコンは `desktop/scripts/generate-icon.swift` が `web/public/icon.svg` から作る。
- Tabghostty.app のバンドル ID は `com.tabghostty.app` で、`com.webtabinal.app` とは別である（Phase 1 D8）。そのため、通知の許可は別に取る必要がある。

## Goals / Non-Goals

**Goals:**

- デスクトップの入口を Tabghostty.app に一本化し、インストール、更新、移行の手順を文書化する。
- 更新したときに古いデーモンが残っているかを、About パネルで確かめられるようにする。

**Non-Goals:**

- デーモンのバージョンを API で照合して、自動で再起動すること。デーモンにはバージョンを返す API が無く、再起動するとシェルのセッションが失われる。手順を書くだけにとどめる。
- 配布（署名や notarization、Homebrew Cask など）。今と同じく、ローカルでビルドして ad-hoc 署名で使う前提とする。
- 新しいアイコンのデザイン。ひとまず WebTabinal と同じものを使う。
- webtabinal の `desktop/` の削除や README の更新（webtabinal は変更しない。D4）。

## Decisions

### D1. `make install` はデーモンを止めない

- 処理の流れ:
  1. `make app` でビルドする。
  2. `osascript -e 'quit app "Tabghostty"'` で起動中のアプリを終了する。
  3. `/Applications/Tabghostty.app` を削除し、新しいバンドルをコピーする。
  4. 次の手順を表示する。

     「同梱のデーモンを新しくするには、セッションを閉じてよいときに `pkill -f 'webtabinal-daemon serve'` を実行してから、Tabghostty を起動し直してください」
- デーモンを自動で止めないのは、PTY のセッションがデーモンに属しているから。止めると、作業中のシェルが失われる（エージェントのタブは restore で戻るが、それ以外は戻らない）。

**採用しなかった案:**

- webtabinal の README のように、`make install` の中で pkill する: 利用者の作業中のシェルを、黙って落とすことになる。

### D2. アイコン

- webtabinal の `desktop/scripts/generate-icon.swift` を `scripts/generate-icon.swift` に移植する。移植元と同じく、SVG を各サイズのビットマップに描き、ImageIO で `.icns` に直接書き出す（`iconutil` は使わない）。CLT だけで動くことを確認する。
- 元画像は `Resources/icon.svg` として、リポジトリに置く。初期値は webtabinal の `web/public/icon.svg` のコピーで、後から差し替えられる。
- `build-app.sh` で `Contents/Resources/AppIcon.icns` に置き、`Info.plist` に `CFBundleIconFile=AppIcon` を設定する。

### D3. About パネル

- `NSApp.orderFrontStandardAboutPanel(options:)` を使い、`.applicationVersion` に `CFBundleShortVersionString` を入れる。`.credits` には `Bundled daemon: <TabghosttyDaemonRevision>` を入れる。

### D4. webtabinal は変更しない

- Phase 6 の方針（webtabinal のリポジトリは変更しない）に合わせ、webtabinal の `desktop/`、`Makefile` の `desktop` / `desktop-test`、README、`openspec/specs/desktop-shell` はそのまま残す。
- デスクトップの入口の一本化は、利用者の環境で行う。Tabghostty の README の「WebTabinal.app からの移行」に従って移り、`/Applications/WebTabinal.app` を削除する（tasks 4.2）。
- webtabinal を変更していないことは、`git -C ../webtabinal status` に変更が無く、HEAD が取り込み元の `6dca08f` のままであることで確かめる。

**採用しなかった案:**

- webtabinal で別の change（例: `retire-desktop-shell`）を起票し、`desktop/` と `make desktop` / `desktop-test` を削除し、README のデスクトップの入口を Tabghostty に向け、`desktop-shell` spec を REMOVED にする: 当初の案（Phase 6 の方針の変更より前に書いたもの）。webtabinal を変更しない方針と食い違うので、採用しない。

### D5. README の構成（Tabghostty）

1. 概要（webtabinal デーモンのネイティブクライアントであること、ブラウザ版と同じセッションを共有すること）
2. 必要なもの
3. クイックスタート
4. 更新の手順
5. WebTabinal.app からの移行
6. 使い方（タブ、ショートカット、検索、リンク、画像の添付、設定）
7. Web 版との違い
8. 画像プロトコル
9. 既知の制約
10. 開発（`make deps`、`build`、`test`、`app`、`fixtures`、環境変数）

## Risks / Trade-offs

- **[Risk] WebTabinal.app を削除した後、Tabghostty に深刻な不具合が見つかる。** → webtabinal の `desktop/` は残るので、webtabinal で `make desktop` を実行すれば WebTabinal.app を作り直せる。Phase 4 で 1 週間使い込んでいるので、可能性は低い。
- **[Trade-off] webtabinal の README は、WebTabinal.app をデスクトップの入口として案内したままになる。** → Tabghostty の README に、WebTabinal.app を置き換えるものであることと、移行の手順を書く。webtabinal を変更しない方針を優先して、許容する。
- **[Risk] 古いデーモンが残っていて、新しい Tabghostty との組み合わせで問題が起きる。** → About パネルで、同梱しているリビジョンを確認できる。README の更新の手順に、デーモンを止める手順と、それによってセッションが失われることを明記する。
- **[Trade-off] アイコンが WebTabinal と同じなので、移行期間中は 2 つのアプリを見分けにくい。** → 移行が終われば WebTabinal.app は無くなるので、許容する。
