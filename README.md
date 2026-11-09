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

### libghostty-vt のバージョンを上げるとき

1. `scripts/libghostty.lock` の `LIBGHOSTTY_VERSION` を変え、`LIBGHOSTTY_SHA256` を空にする。
2. `bash scripts/fetch-libghostty.sh --pin` を実行する。署名を検証した `SHA256SUMS` から、SHA-256 が lock に書き込まれます。
3. `make deps && make test` を実行し、`Sources/TerminalCore/README.md` の C API 対応表を新しいヘッダに合わせて見直す。

### C API

libghostty-vt の C 関数・型と、SPEC.md §3 の概念との対応は [Sources/TerminalCore/README.md](Sources/TerminalCore/README.md) にまとめています。実装では、この表にある名前だけを使います。
