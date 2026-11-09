# Proposal: Phase 0 — libghostty-vt を組み込んだ Swift パッケージの土台

## Why

Tabghostty には今のところ `SPEC.md` と README しかなく、ビルドもテストもできない。SPEC.md（§7 Phase 0）は、描画や接続の作業に入る前に次の 2 点を固めることを求めている。

- libghostty-vt 1.0 を取得してリンクできる状態にする。
- 実在する C 関数名を確認する（推測で書いたコードを防ぐため）。

後続の Phase 1〜7 はすべてこの土台の上に積む。

## What Changes

- リポジトリ直下に SwiftPM パッケージを新設する。
  - Swift 6、最小 macOS 14。
  - ターゲットは SPEC §6 の `native/` 構成を、リポジトリ直下に移した形で作る（`Sources/`、`Tests/`、`Vendor/`、`scripts/`）。
- `scripts/fetch-libghostty.sh` を追加する。
  - libghostty-vt 1.0 のリリース物を取得し、ピン留めしたチェックサムで検証する（公開署名があればそれも検証する）。
  - 検証後、`Vendor/GhosttyVt.xcframework` に配置する。この配置物は git 管理外にする。
  - 公式の XCFramework が無い場合は、`PACKAGING-LIBGHOSTTY.md` の手順に従い Zig でビルドする。
- `TerminalCore` に最小限の Swift ラッパーを置く。できることは 3 つだけ: Terminal の生成、バイト列の書き込み、plain フォーマッタでのテキスト取得。
- 動作確認のテストを追加する。`"Hello\r\n\x1b[31mRed\x1b[0m"` を書き込み、plain 出力が `Hello\nRed` になることを確認する。テストは CLT だけで動く Swift Testing で書く。
- `Sources/TerminalCore/README.md` を追加する。SPEC §3 の各概念（Terminal、RenderState、KeyEncoder、MouseEncoder、effect、選択、検索、フォーマッタ、Snapshot、Kitty Graphics）が、どの C 関数・型に対応するかをまとめた表を置く。
- 開発用の `Makefile` ターゲットを追加する: `deps`、`build`、`test`。
- `.gitignore` に SwiftPM と Vendor の除外を追加する。README に開発環境の準備手順を書く。

## Capabilities

### New Capabilities

- `build-system`: libghostty-vt の取得と検証、最小 OS、開発コマンド（deps / build / test）、配置物を git 管理外にすること。
- `terminal-engine`: VT バイト列から端末状態を作り、テキストとして取り出す VT エンジン層。この Phase では生成・書き込み・plain 取得だけを定める。effect、リサイズ、スクロールバックは Phase 1 で追加する。

### Modified Capabilities

（なし。既存 spec はない）

## Impact

- 新規ファイル: `Package.swift`、`Sources/*`、`Tests/*`、`scripts/fetch-libghostty.sh`、`Makefile`、`Sources/TerminalCore/README.md`。
- 変更ファイル: `.gitignore`、`README.md`。
- 新しい外部依存: libghostty-vt 1.0（バイナリ）。
- ビルド環境: Swift 6 toolchain（Command Line Tools で可）。公式 XCFramework が無い場合だけ Zig が必要になる。
- webtabinal リポジトリには触れない。
