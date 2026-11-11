# Proposal: ウィンドウの位置と大きさを次の起動で戻す

## Why

spec の app-shell「Main window」は、ウィンドウの枠（位置と大きさ）を次の起動でも戻すことを求めている。しかし実際には、ウィンドウの大きさを変えてから終了しても、次の起動では毎回 1100×720 の中央で開く。

原因は `MainWindowController.init()` にある。

- 今のコードは、`window.setFrameAutosaveName("TabghosttyMain")` を `super.init(window:)` より前に呼んでいる。
- `NSWindowController.init(window:)` は、ウィンドウの自動保存名を、コントローラ自身の `windowFrameAutosaveName`（空）で上書きする。
- そのため、枠は一度も保存されず、復元もされない。

次のことを確かめた（2026-11-11）。

- `/Applications/Tabghostty.app`（`com.tabghostty.app`）のユーザーデフォルトのドメインが存在しない。
- 同じ順序で組んだ最小のプログラムで、コントローラを作った直後に `frameAutosaveName` が空になる。

## What Changes

- **自動保存名を `super.init(window:)` の後に設定する**
  - `NSWindowController.windowFrameAutosaveName` で設定する。
  - これで、ウィンドウを動かしたり大きさを変えたりするたびに、枠が保存される。次の起動では、その位置と大きさで開く。
- **終了の経路によらず、同じ枠に戻ることを spec に明記する**
  - 対象の経路: 閉じるボタン、Command-Q、最後のタブを閉じる。
  - 初めての起動（保存された枠が無いとき）は、今までどおり 1100×720 の中央で開く。
  - 保存した枠が、今つながっていない画面の上にあったときは、大きさを保ったまま、つながっている画面に出す。
- **テストを追加する**
  - `MainWindowController` を作った後も自動保存名が残っていること。
  - 保存された枠で開くこと。
  - テストでは、ほかのテストやアプリ本体と名前がぶつからないよう、自動保存名を差し替えられるようにする。

利用者から見た変更は、「大きさと位置が戻るようになる」ことだけである。設定画面の項目は追加しない。

## Capabilities

### New Capabilities

（なし）

### Modified Capabilities

- `app-shell`: 「Main window」の要件を具体的にする。次の 3 点を明記し、シナリオを足す。
  - 枠は動かしたり大きさを変えたりするたびに保存され、終了の経路によらず次の起動で戻ること。
  - 初めての起動での大きさ。
  - つながっていない画面の上で保存された枠の扱い。

## Impact

- `Sources/TabghosttyApp/MainWindowController.swift`（`init`。自動保存名を設定する位置と、テスト用に差し替えられるようにすること）
- `Tests/TabghosttyAppTests/`（新しいテスト）
- 保存先: `com.tabghostty.app` のユーザーデフォルトの `NSWindow Frame TabghosttyMain`（AppKit の標準の仕組み）。デーモンや config.json は変更しない。ブラウザ版にも影響しない。
- 既存の利用者への影響: 今は何も保存されていないので、移行は不要。修正後の最初の起動は今までどおり 1100×720 の中央で開き、それ以降は前回の枠で開く。
