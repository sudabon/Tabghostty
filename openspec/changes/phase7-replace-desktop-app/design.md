# Design: Phase 7 — WebTabinal.app から Tabghostty.app への置き換え

## Context

- Tabghostty はクライアント専用。デーモンと Web 版は webtabinal に残る（2026-11-09 決定）。
- SPEC §7 Phase 7 は、`webtabinal/native/` があることを前提に、次の 3 点を挙げている。
  - `make desktop` をネイティブ版に向ける。
  - `desktop/` を削除する。
  - README の 5 つの節を更新し、Zig を必要なツールに加える。

  本リポジトリの構成に合わせて、これを「Tabghostty 側の整備」と「webtabinal 側の後片付け」の 2 つに分ける。
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

- webtabinal の `desktop/scripts/generate-icon.swift` を `scripts/generate-icon.swift` に移植する。SVG → 各サイズの PNG → `iconutil` → `.icns` の流れで、CLT だけで動くことを確認する。
- 元画像は `Resources/icon.svg` として、リポジトリに置く。初期値は webtabinal の `web/public/icon.svg` のコピーで、後から差し替えられる。
- `build-app.sh` で `Contents/Resources/AppIcon.icns` に置き、`Info.plist` に `CFBundleIconFile=AppIcon` を設定する。

### D3. About パネル

- `NSApp.orderFrontStandardAboutPanel(options:)` を使い、`.applicationVersion` に `CFBundleShortVersionString` を入れる。`.credits` には `Bundled daemon: <TabghosttyDaemonRevision>` を入れる。

### D4. webtabinal に渡す変更案（webtabinal で別の change として実施する）

- `desktop/` と、`Makefile` の `desktop` / `desktop-test` ターゲットを削除する。
- README を次のように変える。
  - **「クイックスタート（推奨: デスクトップアプリ）」**: Tabghostty.app を案内し、リポジトリの URL と `make app` / `make install` の手順に誘導する。
  - **「デスクトップアプリの更新」**: Tabghostty の README に誘導する。LaunchAgent を入れ直す手順は残す。
  - **「画像プロトコル」**: ブラウザ版での対応（kitty / Sixel / IIP）は残し、Tabghostty は Kitty Graphics のみであることを書き添える。
  - **通知のトラブルシュート表**: 「`.app` 更新後も旧挙動」の行の参照先を、Tabghostty にする。
- `openspec/specs/desktop-shell` を REMOVED にする。理由は「デスクトップのシェルを Tabghostty（別リポジトリ）に移したため」、移行先は Tabghostty。
- 実施する時期は、Tabghostty の README が整い、`make install` で置き換えられることを確認した後にする。

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

- **[Risk] WebTabinal.app を削除した後、Tabghostty に深刻な不具合が見つかる。** → webtabinal 側は git で戻せる。Phase 4 で 1 週間使い込んでいるので、可能性は低い。それでも、webtabinal 側の削除は Tabghostty の README を整えた後に、別の change として行う。
- **[Risk] 古いデーモンが残っていて、新しい Tabghostty との組み合わせで問題が起きる。** → About パネルで、同梱しているリビジョンを確認できる。README の更新の手順に、デーモンを止める手順と、それによってセッションが失われることを明記する。
- **[Trade-off] アイコンが WebTabinal と同じなので、移行期間中は 2 つのアプリを見分けにくい。** → 移行が終われば WebTabinal.app は無くなるので、許容する。
