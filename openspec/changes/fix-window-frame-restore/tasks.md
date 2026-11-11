# Tasks

> 対象の spec: app-shell「Main window」。方針は design D1〜D3。

## 1. 自動保存名の修正とテスト（spec: app-shell「Main window」）

- [x] 1.1 `Tests/TabghosttyAppTests/MainWindowFrameTests.swift` を追加し、次の 3 つのテストを書く。修正前のコードでは、少なくとも (a) と (b) が失敗することを `make test` で確かめる
  - 実装済み（2026-11-11）: (c) の 2 つの確認は、別の `@Test` に分けた（`savesTheFrameWhenItChanges` と `opensAtTheInitialSizeWithoutASavedFrame`）。保存値は `NSWindow.removeFrame(usingName:)` で消す。画面が無いときは、`.enabled` で (b) と (c) を飛ばす
  - 修正前のコード（`init` に名前の引数だけを足したもの）で実行した結果: (a) と (c) の保存の確認が失敗した。(b) は予想に反して通った。`window.setFrameAutosaveName` は、呼んだその場で保存済みの枠を適用する。コントローラが名前を空にするのはその後なので、枠は残る。壊れていたのは保存の側だけだった（保存されないので、結局戻るものは無い）
  - 名前はテストごとに一意（UUID を含む）にし、終わったらその名前の保存値を `UserDefaults.standard` から消す（design D2）
  - (a) `MainWindowController(frameAutosaveName:)` を作った後、`window.frameAutosaveName` がその名前になっている
  - (b) 別の `NSWindow` で `saveFrame(usingName:)` を使って、`NSScreen.main?.visibleFrame` に収まる 640×400 の枠を保存してから、コントローラを作る。ウィンドウがその枠で開く。画面が無いときは、このテストを飛ばす
  - (c) コントローラのウィンドウに `setFrame` で別の枠を設定すると、別の `NSWindow` の `setFrameUsingName(_:)` が `true` を返し、同じ枠になる。保存値が無い名前で作ったときは、内容の大きさが 1100×720 で開くことも確かめる（枠の高さにはタイトルバーが入るので、`contentRect(forFrameRect:)` で比べる）
- [x] 1.2 `MainWindowController.init` を design D1 / D2 のとおりに変える。`make test` で 1.1 のテストと既存のテスト（`ConnectionLostBannerTests` など）がすべて通ることを確かめる
  - 実装済み（2026-11-11）: `super.init(window:)` と `window.delegate = self` の後で、`windowFrameAutosaveName` を設定する。`make test` で、`MainWindowFrameTests` の 4 つを含むすべてのテストが通った（スキップは、ベンチマーク用に既定で無効にしているものだけ）
  - `init(frameAutosaveName: String = Self.autosaveName)` にする
  - `window.setFrameAutosaveName` の呼び出しをやめる
  - `super.init(window:)` の後で `windowFrameAutosaveName` を設定する
  - `window.center()` は、名前を設定する前に呼ぶ
  - 名前を設定する箇所のコメントを、上書きされる理由が分かる内容に直す
- [x] 1.3 README の「クイックスタート」の箇条書き（「ウィンドウを閉じるとアプリは終了しますが…」の近く）に、「ウィンドウの位置と大きさは、次の起動で戻ります」を足す。README を開いて、その一文があることを確かめる

## 2. 実機での確認

- [ ] 2.1 `make install` の後、次の 3 つの経路のそれぞれで、ウィンドウの大きさと位置を変えてから終了し、`open /Applications/Tabghostty.app` で同じ枠に戻ることを確かめる（要手動確認）
  - 閉じるボタン
  - Command-Q
  - 最後のタブを閉じる
  - あわせて、`defaults read com.tabghostty.app "NSWindow Frame TabghosttyMain"` に値があることを確かめる
- [ ] 2.2 `defaults delete com.tabghostty.app "NSWindow Frame TabghosttyMain"` の後に起動すると、1100×720 の中央で開くことを確かめる（要手動確認）
- [ ] 2.3 外部ディスプレイの上にウィンドウを置いて終了し、ディスプレイを外してから起動すると、内蔵の画面に同じ大きさで、すべて見える状態で開くことを確かめる（要手動確認。外部ディスプレイが無ければ、design D3 の確認結果を根拠として、そのことを記録する）
- [ ] 2.4 起動直後の「接続中」の画面から保存した枠で開き、つながった後に端末を表示しても枠が変わらないことを確かめる（要手動確認）
