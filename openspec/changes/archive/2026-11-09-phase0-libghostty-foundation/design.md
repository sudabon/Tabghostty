# Design: Phase 0 — libghostty-vt を組み込んだ Swift パッケージの土台

## Context

- Tabghostty は**ネイティブクライアント専用**のリポジトリにする（2026-11-09 決定）。
  - Go デーモン、`web/`、旧 `desktop/` は webtabinal（`github.com/sudabon/webtabinal`）に残す。
  - Tabghostty は既存の REST + WebSocket プロトコルでデーモンに接続する。
- SPEC.md は `webtabinal/native/` を前提に書かれている。本リポジトリではその `native/` をリポジトリ直下に読み替える（例: SPEC の `native/Sources/TerminalCore/` は本リポジトリの `Sources/TerminalCore/`）。
- 開発機の環境（2026-11-09 時点）:
  - Swift 6.4。Command Line Tools のみで、Xcode 本体は入っていない。
  - Zig は入っていない。Go と Node は入っている。
- CLT には `Testing.framework`（Swift Testing）が同梱されているが、`XCTest.framework` は無い。
- 最小 macOS は 14（2026-11-09 決定。`NSView.displayLink` を使うため）。

## Goals / Non-Goals

**Goals:**

- `make deps && make test` だけで、libghostty-vt をリンクしたテストが通る状態にする。
- 後続 Phase のモジュール境界（SPEC §6）をこの時点で切っておく。
- 実在する C API 名を文書化し、以降の実装で関数名を推測しなくて済むようにする。

**Non-Goals:**

- デーモン接続、描画、入力。これらは Phase 1 以降で扱う。
- `.app` バンドルの作成。デーモンの起動に必要になる Phase 1 で扱う。
- effect、リサイズ、スクロールバック設定のラッパー。Phase 1 で `terminal-engine` に追加する。

## Decisions

### D1. パッケージはリポジトリ直下に置く（`native/` を作らない）

- このリポジトリの中身はネイティブクライアントだけなので、`native/` 階層を挟む意味がない。
- SPEC のパスとは「`native/` を外す」という一定の規則で対応が取れる。

構成:

```
Package.swift                 // swift-tools-version: 6.0, platforms: [.macOS(.v14)]
Sources/
  Tabghostty/                 // @main（Phase 1 で中身を入れる。Phase 0 では空の main）
  DaemonClient/               // Phase 1
  TerminalCore/               // libghostty-vt の Swift ラッパー（Phase 0 で最小実装）
    README.md                 // C API 対応表
  TerminalUI/                 // Phase 1
  Shell/                      // Phase 3
  DesktopSupport/             // Phase 1（webtabinal desktop/ から移植）
Tests/
  TerminalCoreTests/
  DaemonClientTests/          // Phase 1
  ShellTests/                 // Phase 2〜
Vendor/                       // git 管理外。GhosttyVt.xcframework を置く
scripts/
  fetch-libghostty.sh
  libghostty.lock             // バージョン、URL、SHA-256
Makefile
```

Phase 0 で作るのは `TerminalCore`、`TerminalCoreTests`、空の `Tabghostty` 実行ターゲットだけにする。ほかのターゲットはそれぞれの Phase で追加する。中身の無いターゲットを先に作って保守する手間を避けるため。

**採用しなかった案:** `native/` サブディレクトリを作る（SPEC と同じ構成）。パスが一致する利点はあるが、このリポジトリでは意味のない 1 階層が増えるだけなので採らない。

### D2. libghostty-vt の入手は「公式の配布物を優先、無ければ Zig でビルド」

`scripts/fetch-libghostty.sh` の動き:

1. `scripts/libghostty.lock` からバージョン、URL、SHA-256（あれば署名の公開鍵も）を読む。
2. 配布物をダウンロードする。
3. SHA-256 を照合する。上流が署名（minisign など）を公開していれば、それも検証する。
4. 一時ディレクトリに展開してから、`Vendor/GhosttyVt.xcframework` へアトミックに移動する。

公式 XCFramework が無いと分かった場合の手順:

- ソースの tarball を同じ方法で検証する。
- `PACKAGING-LIBGHOSTTY.md` の手順で、Zig を使って `xcframework` を生成する。
- 必要な Zig のバージョンも lock に記録し、スクリプトの冒頭で確認する。

lock ファイルを分けたのは、バージョンを上げるときにスクリプト本体の差分とレビューを分けるため。

**採用しなかった案:**

- git submodule でソースを取り込み、毎回ビルドする: 開発機ごとに Zig が必要になり、ビルドも遅い。
- 配布物をリポジトリにコミットする: バイナリでリポジトリが肥大化する。署名を検証する経路も失う。

### D3. C との接続は `binaryTarget` を使い、必要なら shim ターゲットを挟む

- XCFramework の `Headers/` に `module.modulemap` が入っていれば、`binaryTarget(name: "GhosttyVt", path: "Vendor/GhosttyVt.xcframework")` を直接 import する。
- modulemap が入っていない場合は、`CGhosttyVt` という C ターゲット（umbrella header と modulemap だけ）を挟む。
- どちらになるかは配布物を見て決める。この判断はタスク 2.1 で行う。結果を Swift から使う側は変わらない。

### D4. `TerminalCore` の Phase 0 での公開範囲

```swift
public final class VTTerminal {            // 名前は仮
  public init(cols: Int, rows: Int, maxScrollback: Int) throws
  public func write(_ bytes: some Collection<UInt8>)
  public func plainText() -> String        // フォーマッタ（plain）を使う
}
```

- スレッドを閉じ込める仕組み（actor 化）は Phase 1 の `TerminalController` で入れる。Phase 0 ではテストから同期的に呼ぶだけ。
- C のハンドルは `deinit` で解放する。

### D5. テストは Swift Testing（`import Testing`）で書く

- CLT のみの環境に XCTest が無いことを確認済み。webtabinal の `desktop/` は独自のテストランナー（`Tests/main.swift`）で回避していた。
- 本リポジトリでは CLT に同梱されている Swift Testing を使い、`swift test` で完結させる。
- （実装時の補足、2026-11-09）CLT の Swift 6.4 では、既定のビルドシステム（swiftbuild）で `swift build` と `swift test` を交互に実行すると、`TestingMacros` プラグインが見つからずにテストのコンパイルが失敗することがある。その場合、失敗したコマンドには `-load-resolved-plugin` が `SwiftMacros` の分しか付いていなかった。
  - 回避策: `make test` で、toolchain から求めた `…/lib/swift/host/plugins/testing` を `-Xswiftc -plugin-path` で明示的に渡す。この状態で、`build` と `test` を交互に実行しても失敗しないことを確認した。
  - `--build-system native` では、`Testing` モジュール自体が見つからない。`swift build --build-tests` も、テストのコンパイルに失敗する。そのため、テストの実行は `make test`（`swift test`）に一本化する。

### D6. C API 対応表は、ヘッダを読みながらその場で作る

- `Sources/TerminalCore/README.md` に表を置く。
- 列は「SPEC §3 の概念 / Go バインディング名 / C 関数・型名 / ヘッダファイル / 備考（スレッド制約、所有権、Phase）」。
- Phase 1 以降のタスクは、この表にある名前だけを使う前提で書く。
- 表に無い機能が必要になった場合は、ヘッダを確認して表に追記してから実装する。

## Risks / Trade-offs

- **[Risk]** 公式の XCFramework が無く、Zig でのビルドが必要になる。 → D2 の分岐で対処する。必要な Zig のバージョンは lock に固定し、README に `brew install zig`（またはバージョン指定のインストール手順）を書く。
- **[Risk]** CLT 同梱の Swift Testing が、`swift test` から正しく検出されない。 → 最初のタスクでサンプルテストを走らせて確認する。動かなければ、webtabinal と同じく実行ターゲット型の独自ランナー（`swift run TabghosttyTests`）に切り替える。
- **[Risk]** libghostty-vt の C API に、SPEC §3 が想定している機能（選択、検索、Snapshot など）が無い。 → 対応表で「なし」と明記する。どの Phase に影響するかを備考に書き、その Phase に着手する前に設計を見直す。
- **[Trade-off]** ダウンロード時に検証することで、オフライン環境では初回ビルドができない。 → 一度取得すれば再取得しない（冪等）ので、運用上は問題にならない。

## Migration Plan

新規リポジトリへの追加なので、移行の手順はない。

## Open Questions

- XCFramework に modulemap が同梱されているか（D3）。配布物を見ればすぐ分かり、後続 Phase の作業には影響しない。

## Optional Validation（tasks には含めない）

SPEC §7 Phase 0 の任意作業 4（webtabinal の `web/` で xterm.js を `ghostty-web` に差し替え、表示を見比べる）について:

- これは webtabinal 側に使い捨てのブランチを切って行う検証なので、本 change の tasks には入れない。
- 実施した場合は、結果（表示差分のスクリーンショットと所感）を `docs/phase0-ghostty-web-comparison.md` に残す。
