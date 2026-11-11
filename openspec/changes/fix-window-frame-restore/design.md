# Design: ウィンドウの位置と大きさを次の起動で戻す

## Context

- 不具合の原因は proposal.md「Why」のとおり。
- `MainWindowController` は、アプリにただ 1 つのウィンドウを持つ `NSWindowController` である。`AppDelegate.applicationDidFinishLaunching` で作り、すぐに `showWindow` する。デーモンにつなぐ前（「接続中」の画面）から表示する。
- ウィンドウの大きさを変えるコードは、ほかに無い。`setContentSize`、`contentResizeIncrements` などは使っておらず、中身の差し替え（`setContent`）でも枠は変わらない。
- 最小のプログラムで、AppKit の振る舞いを確かめた（2026-11-11、macOS 26）。
  - `NSWindow.setFrameAutosaveName(_:)` の後に `NSWindowController(window:)` を作ると、`frameAutosaveName` が空になる。その後は、大きさを変えても何も保存されない。
  - `super.init(window:)` の後に名前を設定すると、どちらの API（`window.setFrameAutosaveName` / `controller.windowFrameAutosaveName`）でも、保存された枠がその場で適用される。動かしたり大きさを変えたりするたびに、`NSWindow Frame <name>` に保存される。`showWindow` の後も枠は変わらない。
  - 保存された枠が、今つながっていない画面の上にあるときは、AppKit が大きさを保ったまま、つながっている画面に移す。
  - 同じ名前のウィンドウがすでにあるときは、名前の設定に失敗する（`setFrameAutosaveName` が `false` を返す）。このときは、保存された枠も適用されない。

## Goals / Non-Goals

**Goals:**

- AppKit の標準の仕組み（frame autosave）だけで、spec の app-shell「Main window」を満たす。
- 自動保存名が上書きされるという、今回の不具合が戻ってこないことを、テストで確かめる。

**Non-Goals:**

- フルスクリーンやしまった（最小化した）状態を、次の起動で戻すこと。戻すのは位置と大きさだけである。
- ウィンドウの状態の復元（`NSWindowRestoration` / Saved Application State）を使うこと。
- サイドバーの幅を覚えておくこと（spec の tab-sidebar の範囲で、この change では扱わない）。
- 設定画面のウィンドウの位置。

## Decisions

### D1. 自動保存名は `super.init(window:)` の後に、`windowFrameAutosaveName` で設定する

- `NSWindowController` が管理するウィンドウでは、自動保存名はコントローラの `windowFrameAutosaveName` で持つ。これが AppKit の想定する使い方である。
- コントローラの値が空のままだと、今後 AppKit が改めて名前を適用する経路があったときに、また上書きされるおそれがある。
- `init()` の流れは次のとおり。

  ```
  window を作る → minSize などを設定 → window.center()   // 保存された枠が無いときの位置
  super.init(window:)
  windowFrameAutosaveName = <名前>                        // 保存された枠があれば、ここで適用される
  ```

- `window.center()` は、名前を設定する前に呼ぶ。保存された枠が無いときは中央の 1100×720 のままになり、あるときは名前の設定で上書きされる。

**採用しなかった案:**

- `super.init` の後に `window.setFrameAutosaveName` を呼ぶ: 今は同じように動く。ただし、コントローラの値は空のままになり、上の理由で壊れやすい。
- 終了するときに、自前で `UserDefaults` に枠を書き、起動するときに読む: AppKit がすでにしていること（画面が変わったときの補正を含む）を、作り直すことになる。

### D2. 自動保存名をテストで差し替えられるようにする

- `init(frameAutosaveName: String = MainWindowController.autosaveName)` とする。アプリ本体は既定値を使う。
- 理由:
  - 同じ名前のウィンドウが同時に 2 つあると、2 つ目では名前の設定に失敗する。テストは同じプロセスで `MainWindowController` をいくつも作るので（`ConnectionLostBannerTests` など）、名前がぶつかると結果が不安定になる。
  - テストがアプリ本体の名前で枠を書くと、テストの実行プロセスのユーザーデフォルトに、本体と同じキーが残る。
- テストでは、テストごとに一意の名前（UUID を含む）を使い、終わったらその名前の保存値を消す。
- 保存値の形式（`NSWindow Frame <name>` の文字列）に依存しないように、確かめるときは AppKit の API を使う。
  - 保存の確認: 別の `NSWindow` で `setFrameUsingName(_:)` を呼び、その枠になること。
  - 復元の確認: 別の `NSWindow` で `saveFrame(usingName:)` を呼んでから `MainWindowController` を作り、その枠で開くこと。

### D3. 画面が変わったときの補正は、AppKit に任せる

- spec の「Saved on a disconnected display」は、AppKit の標準の動き（上の確認結果）で満たせる。自前の補正は書かない。
- 単体テストでは、画面の構成を変えられない。そのため、この項目は手動で確かめる（tasks.md）。

## Risks / Trade-offs

- [テストを実行する環境（CI など）に画面が無い、または小さいと、保存した枠が画面に収まるよう補正され、期待した値と合わないことがある] → テストで使う枠は、`NSScreen.main?.visibleFrame` に収まる小さな値（例: 原点から少し離れた 640×400）にする。画面が無いときは、そのテストを飛ばす。
- [AppKit の今後の版で、`NSWindowController` の名前の扱いが変わる] → D1 でコントローラの API を使い、D2 のテストで「作った後に名前が残っていること」と「保存された枠で開くこと」を確かめる。
- [保存された枠が `minSize`（320×200）より小さい] → AppKit が `minSize` に合わせる。手で縮められるのは `minSize` までなので、通常は起きない。

## Migration Plan

- 移行は不要（proposal.md「Impact」）。修正後に初めて起動したときは、今までどおり中央の 1100×720 で開く。その後に動かしたり大きさを変えたりした時点から、保存される。
- 元に戻すときは、この変更を取り消すだけでよい。保存値が残っていても、名前が上書きされる状態では読まれないので、害は無い。消したいときは `defaults delete com.tabghostty.app "NSWindow Frame TabghosttyMain"` を実行する。
