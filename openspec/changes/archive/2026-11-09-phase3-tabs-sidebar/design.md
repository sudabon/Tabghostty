# Design: Phase 3 — タブ・サイドバー・状態表示・ショートカット

## Context

- Phase 2 までの時点で、`TerminalController` はセッションごとに独立している。ただし attach と描画をしているのは、アクティブな 1 セッションだけである。
- 置き換え元の Web 版の挙動（webtabinal `6dca08f`）:
  - **attach しているタブ**: アクティブな 1 つだけで、切り替えるたびに xterm を作り直して replay している。デーモンに detach が無いので、一度 attach した sid の `output` は届き続け、クライアント側で sid を見て捨てている。
  - **アクティブの選び方**: 一覧に残っていれば維持し、無ければ先頭にする（Phase 1 で実装済み）。
  - **未読**（`App.tsx` L224-275）:
    - `shouldRaiseDesktopNotification` を通り、かつ非アクティブのタブで付く。この判定は `enabled` と、完了通知の場合の `min_duration_ms` を見る。
    - 付けるのはミュートやコマンド一覧での判定より前なので、ミュートしていても付く。
    - 消えるのは `select` したときだけ。閉じたタブを取り除かない（不具合）。
  - **Dock バッジ**: ブラウザの `navigator.setAppBadge` だけで、旧 `.app` にはバッジのコードが無い。
  - **コード**（`keymap.ts`）:
    - キーの正規化、検証の順序、状態遷移、3 秒のタイムアウト。
    - window の keydown を capture フェーズで処理する。
    - 設定画面やメモを開いているとき、テキストフィールドにフォーカスがあるときは無効。
    - 保留中は画面の下中央に pill を出す。
  - **Cmd+1〜9 / Cmd+N**: 設定画面を開いているときだけ無効。
  - **サイドバー**:
    - リサイザは 6px で、160〜480 に収める。離したときに `PATCH {sidebar_width}` を送る。
    - 折りたたみはメモリ上の状態だけで、保存しない。
  - **メモ**: 30 code point で切り詰める。Enter（変換中は除く）で保存し、Escape で取り消す。保存に失敗したら開いたままにする。
  - **右クリックメニュー**: 項目は 4 つ。再起動は終了済みのときだけ押せる。
- `run_ms` が更新されるのはフレームを受け取ったときだけで、Web 版には時間を進めるタイマーが無い。

## Goals / Non-Goals

**Goals:**

- SPEC §7 Phase 3 の完了条件を満たす。
  - タブの並び、メモ、ミュートがブラウザ版との間で即時に反映される。
  - pill が出る。
  - 未読と Dock バッジが付く。
  - ショートカットがターミナルに漏れない。
- 全タブを attach することで、タブを切り替えても replay をしないようにする。

**Non-Goals:**

- 通知バナー、通知の許可、コマンド一覧での絞り込み（Phase 4）。ただし、未読の判定に使う `notification.enabled` と `min_duration_ms` は、Phase 3 で config から読む。
- 設定画面（Phase 4）。`key_bindings`、`confirm_close_running`、`quit_when_no_tabs` は、起動時に config から読む。
- 経過時間を進めるタイマー（Web 版と同じく、フレームを受け取ったときだけ更新する）。

## Decisions

### D1. 全タブ attach と表示の切り替え

- `SessionStore` が `sessions` を受け取るたびに、一覧との差分を取る。増えた sid には `TerminalController` を作って attach し、消えた sid のコントローラは破棄する。
- `TerminalView` は 1 つにして、表示するコントローラを差し替える方式にする。切り替えたら、そのコントローラの RenderState を全行 dirty にして描画する。ビューをタブの数だけ持つと、`NSTextInputClient` の状態やフォーカスの扱いが複雑になるため。
- 未確定の IME 文字列、選択範囲、viewport の位置は、コントローラ側に持たせる。切り替えても失われない。
- グリッドサイズはウィンドウで 1 つにする。変わったら、live の全コントローラに resize を指示する（spec: terminal-session）。
  - iTerm2 や Terminal.app でも、同じウィンドウの裏のタブはリサイズされる。
  - Web 版はアクティブのタブにしか resize を送らないが、Tabghostty では全タブを attach しているので、ローカルの Terminal と PTY のサイズを一致させることを優先する。

**実装メモ（2026-11-09）:**

- IME の変換（入力メソッドのセッション）はビューに結び付いていて、コントローラごとに保存して戻すことはできない。そのため、切り替えるときは未確定の文字列だけを前のコントローラに預けて変換を終わらせ、戻ったときに表示だけを戻す。戻した文字列は IME が知らないので、次のキーで確定（Enter。ほかのキーは、そのキーを処理する前に確定）・取り消し（Escape）・1 文字削除（Backspace）する。
- 再接続したときは、`connected` の時点ではなく、直後に届く `sessions` で一覧に残っているセッションだけを attach し直す（デーモンが再起動して消えたセッションに attach しない）。

**採用しなかった案:**

- 裏のタブは resize しない: ローカルの Terminal（新しいサイズ）と PTY（古いサイズ）がずれ、裏で出た出力の表示が崩れる。
- タブごとに `TerminalView` を持つ: 上で述べた IME とフォーカスの理由で採らない。

### D2. サイドバーの実装

- `NSSplitView`（左がサイドバー、右がターミナル領域）を使う。サイドバーは `NSTableView`（ビューベース、1 列）。
  - `NSSplitViewController` の `NSSplitViewItem(sidebarWithViewController:)` を使えば、折りたたみの操作とアニメーションが標準のものになる。
  - 幅を 160〜480 に収める処理は、`minimumThickness` / `maximumThickness` で行う。
- 行は `TabRowView` で、3 段のラベル、`◌`、未読ドット、`AgentStatePillView` を並べる。
- 並べ替えは `NSTableView` のドラッグ＆ドロップで行い、ドロップしたら `PUT /api/sessions/order` を送る。ローカルの並びは変えず、デーモンの broadcast を待つ（Web 版と同じ）。
- 配色は Web 版の chrome トークン（`web/src/index.css`）を `ChromePalette` に移植する。値は Phase 4 で配色を動的に切り替えるときにも使う。
- メモのツールチップは標準の `toolTip` を使わず、1 秒のディレイで出す独自のポップオーバーにする。標準の `toolTip` では、表示までの時間と、どの操作で隠すかを制御できないため。

**実装メモ（2026-11-09）:** macOS 26 の `NSSplitViewItem(sidebarWithViewController:)` は、サイドバーを枠の内側に浮かせて余白を取る（ガラスの外観）。この余白のため、`minimumThickness` / `maximumThickness` が枠とビューのどちらの幅に効くかがずれ、配色も chrome トークンにならない。そこで、ふつうの `NSSplitViewItem(viewController:)` に最小・最大の幅（160〜480）、`canCollapse`、`holdingPriority` を指定した。折りたたみは `isCollapsed`（アニメーションは `animator()`）で行い、ドラッグでは折りたたまない。ドラッグの終わりは、`NSSplitView.mouseDown`（境界のドラッグをこの中で追跡する）から戻った時点で判定する。行のドラッグは、`NSTableView` の既定の開始条件では 6pt を指定できないので、行のビューが 6pt 動いたのを見てドラッグを始め、ドロップは `NSTableView` で受ける。

### D3. 未読の管理（`UnreadTracker`）と Dock バッジ

- 未読かどうかは、純粋関数 `shouldMarkUnread(event:, session:, isActive:, config:)` で判定する。webtabinal `notify.ts` の `shouldRaise` のうち、未読に関係する部分（`enabled` と完了時の `min_duration_ms`）と、Web 版と同じ「非アクティブであること」を見る。
- 完了イベントは、`SessionStore` が `state` フレームで `running → idle` を検出したときに発行する。待ちイベントは、`notify` フレームの title か body が空でないときに発行する。どちらのイベントも、Phase 4 の通知判定がそのまま使う。
- `sessions` を受け取ったら、一覧に無い sid を未読から取り除く（Web 版の不具合を直す）。
- `NSApp.dockTile.badgeLabel` には、未読の数（0 のときは nil）を入れる。

### D4. キーマップとコード（`Keymap`）

- webtabinal `keymap.ts` を、そのまま Swift に移植する。対象は次のとおり。
  - キーの正規化（`KeyInput` から）
  - 表記の解析
  - 検証（エラーの種類と順序も同じ）
  - コードの状態遷移
  - `neighbourTabIndex`
  - `formatBinding`
- 判定は、`TerminalView.keyDown` の段階 0（Phase 2 D1 で用意した差し込み口）で行う。そこで処理されなかったキーだけを、Phase 2 の経路に流す。
- 設定画面とメモシートを開いているとき、テキストフィールドにフォーカスがあるときは、この判定をしない。その場合、ターミナルにはそもそもフォーカスが無い。
- 保留中の表示は、ウィンドウの下中央に重ねて出す。
- 3 秒のタイムアウトは `DispatchWorkItem` で行う。ウィンドウがフォーカスを失ったとき（`windowDidResignKey`）と、シートを開いたときに取り消す。
- Cmd+N と Cmd+1〜9 はメニューのキー等価物にする。Window メニューに「タブ 1」〜「タブ 9」を置く。

### D5. タブ操作の UI

- 実行中のタブを閉じる確認、メモの編集、危険なペーストの確認は、すべてウィンドウのシートにする（Web 版の desktop shell でも、確認は NSAlert のシートだった）。
- メモの編集シート:
  - `NSTextField` を使い、フォーマッタか `controlTextDidChange` で 30 code point に収める。変換中（`hasMarkedText`）は収める処理をしない。
  - Enter は `control(_:textView:doCommandBy:)` で `insertNewline:` を拾う。変換中は IME が Enter を消費するので、確定と保存が混ざることは無い。
- 右クリックメニューは `NSMenu` を使う。通知の項目は `state = .on` / `.off` で、標準のキーボード操作が使える。
- `quit_when_no_tabs` は、`SessionStore` が「1 件以上 → 0 件」の変化を検出したときに判断する。終了するときは `NSApp.terminate`。デーモンは止めない。

### D6. テストの移植

webtabinal の `web/tests` から、次を Swift Testing に移す。

- `keymap.test.ts`（7 件）: 正規化、表記、検証、状態遷移、隣のタブへの移動。
- `session-state.test.ts`（6 件）: 一覧の置き換え、`state` と `agent_state` の反映。
- `tab-menu.test.ts`: 位置の補正は `NSMenu` を使うので不要。項目が押せるかどうかの判定だけを移す。
- `util.test.ts`: `cwdBasename`、起動時のセッション確保、Unicode の切り詰め。
- `agent-state-pill.test.ts`: 表示するかどうかと、アクセシビリティのラベル。

`app.test.ts` のうち、コード、未読、ミュートに関する部分は、`UnreadTracker` と `SessionStore` の結合テストとして書き直す。

## Risks / Trade-offs

- **[Risk] 全タブを attach すると、メモリと CPU の使用量が増える**（30 タブ × scrollback 10000 行）。→ 計測は Phase 5 の完了条件で行う。問題になった場合は、スクロールバックを使っていないタブを detach しておき、表示するときに replay する方式に切り替えられる。プロトコルの範囲内でできる。
- **[Risk] 全タブに resize を送るので、ブラウザ版で同じタブを別のサイズで見ていると、サイズを取り合う。** → 現行でも、アクティブのタブについては同じことが起きている。アクティブにしたときにサイズを送り直すことで、Tabghostty 側の表示は正しく保つ。
- **[Trade-off] 未読の条件を Web 版に合わせる。** つまり、通知が無効だと未読も付かない。また、出力があっただけでは未読にならない。SPEC §5.2 の「非アクティブタブの出力」とは違うが、SPEC は「現行の未読条件を読んで合わせる」とも書いているので、Web 版に合わせる。
- **[Trade-off] Web 版との差分**: 閉じたタブを未読から取り除くこと、Dock バッジを出すことの 2 点。どちらも不具合の修正と、SPEC で要求されている機能の追加である。
