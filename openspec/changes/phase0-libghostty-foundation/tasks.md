# Tasks

## 1. パッケージの骨組み

- [x] 1.1 `Package.swift` を作る（swift-tools-version 6.0、`platforms: [.macOS(.v14)]`、Swift 6 言語モード）。中身は空の `Tabghostty` 実行ターゲット、`TerminalCore`、`TerminalCoreTests` の 3 つ。`TerminalCoreTests` に `import Testing` のダミーテストを 1 本置き、CLT のみの環境で `swift test` が実行・検出されることを確認する（動かなければ design.md の Risk に従い独自ランナーへ切り替え、design.md を更新する）
- [x] 1.2 `.gitignore` に `.build/`、`.swiftpm/`、`Vendor/*.xcframework`、`Vendor/tmp/`、`build/`（`.app` の出力先）を追加する。`swift build` の後に `git status` がクリーンであることを確認する

## 2. libghostty-vt の取得とリンク

- [x] 2.1 libghostty-vt 1.0 の配布形態を調べる（lib.ghostty.org、GitHub Releases、`PACKAGING-LIBGHOSTTY.md`）。次の 3 点を `scripts/libghostty.lock` に記録し、lock がコミットされていることを確認する
  - 公式 XCFramework の有無（無ければソース tarball と、必要な Zig のバージョン）
  - SHA-256
  - 署名方式
- [x] 2.2 `scripts/fetch-libghostty.sh` を実装し、次の 3 点を確認する
  - `Vendor/GhosttyVt.xcframework` に配置されること
  - 2 回目の実行ではダウンロードしないこと
  - lock の SHA-256 を 1 文字書き換えると非ゼロで終了し、`Vendor/` に新しい成果物が残らないこと

  処理の流れ: lock を読む → ダウンロード → SHA-256（と、あれば署名）を検証 → 一時ディレクトリに展開（Zig ビルドの場合はここでビルド）→ `Vendor/GhosttyVt.xcframework` へアトミックに移動。既に検証済みのものがあれば何もしない。
- [x] 2.3 XCFramework に modulemap が入っているかを確認する（design.md D3）。結果に応じて `binaryTarget` を直接使うか、`CGhosttyVt` shim ターゲットを挟むかを決め、`Package.swift` に組み込む。`TerminalCore` から `import` して `swift build` が通ることを確認する
- [x] 2.4 `Makefile` に `deps`（fetch スクリプトを実行）、`build`（`swift build`）、`test`（`swift test`）を追加する。`Vendor/GhosttyVt.xcframework` が無い状態で `make build` と `make test` を実行すると、「`make deps` を実行してください」と表示されて非ゼロで終了することを確認する

## 3. C API 対応表

- [x] 3.1 `include/ghostty/vt.h` と `include/ghostty/vt/*.h`、配布物の `examples/`、生成ドキュメントを読む。SPEC §3 の各概念を C の関数名・型名に対応させた表を `Sources/TerminalCore/README.md` に書く。表の対象は次のとおり。各行に名前の出典となるヘッダのファイル名を付け、§3 の各概念に行が 1 つ以上あること（ライブラリに無い機能は「なし」と明記されていること）を確認する
  - Terminal の生成・解放・書き込み・リサイズ（セルのピクセルサイズを含む）・リセット
  - 最大スクロールバック
  - RenderState（行・セル・スタイル・色・カーソル・dirty）
  - KeyEncoder、MouseEncoder、フォーカスエンコード
  - ペーストユーティリティ
  - 選択、検索、フォーマッタ（plain / VT / HTML）
  - Kitty Graphics、Snapshot
  - effect の各種類（PTY 書き戻し、ベル、タイトル、クリップボード読み書き、デスクトップ通知、進捗、セマンティックプロンプト）
  - スレッド制約と所有権のルール
- [x] 3.2 対応表の備考欄に、SPEC §9 の未確定事項の調査結果を書く。対象は Sixel / iTerm2 IIP の有無と、C API にあるが SPEC が想定していなかった機能。`Sources/TerminalCore/README.md` に該当行があることを確認する

## 4. 最小ラッパーと動作確認のテスト

- [x] 4.1 `TerminalCore` に `VTTerminal`（仮称）を実装する。機能は生成（cols、rows、最大スクロールバック）、`write(bytes)`、`plainText()` で、C のハンドルは `deinit` で解放する。関数名は 3.1 の表にあるものだけを使う。`swift build` が通ることを確認する
- [x] 4.2 `TerminalCoreTests` に spec `terminal-engine` の各シナリオのテストを書き、`make test` で全件通ることを確認する
  - `Hello\r\n\x1b[31mRed\x1b[0m` → `Hello\nRed`
  - エスケープシーケンスの途中で分割して書き込んでも、結果が一致する
  - `が` を 2 チャンクに分けて書き込んでも、`が` が得られる
  - SGR を含む入力からエスケープバイトが出力されない

## 5. ドキュメント

- [x] 5.1 README に「開発環境」の節を追加し、手順どおりに実行すると fresh clone で `make deps && make test` が通ることを確認する。書く内容は次のとおり
  - 必要なもの（Command Line Tools、Swift 6。Zig は 2.1 の結果に応じて記載）
  - `make deps`、`make build`、`make test`
  - Tabghostty が webtabinal デーモンのネイティブクライアントであること（Phase 1 以降で必要になる旨）
