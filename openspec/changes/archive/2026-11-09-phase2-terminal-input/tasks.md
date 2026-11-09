# Tasks

> 前提: `phase1-single-tab-terminal` が完了し、archive 済みであること。

## 1. キーの判定（spec: terminal-input）

- [x] 1.1 `KeyInput`（値型）と `classifyKey(_:settings:) -> KeyAction` を作る（design D1 の 0〜6）。webtabinal の `web/tests/terminal-input.test.ts` にある Shift+Enter と ¥ のケースを Swift Testing に移植して通ることを確認する。移植するケースは次のとおり
  - 有効 / 無効
  - 修飾キーなしの Enter
  - keydown のときだけ反応すること
  - 変換中
  - 他の修飾キーが付いているとき
  - Enter 以外のキー
  - ¥ の書き換えと、書き換えないケース
- [x] 1.2 `TerminalView.keyDown` を `classifyKey` を使う形に書き換える。Ctrl+文字と文字以外のキーはキーエンコーダに直接渡し、それ以外は `interpretKeyEvents` → `insertText` を通す。`doCommand(by:)` は何もしないようにする。Claude Code で Shift+Enter が改行に、Enter が送信になることを確認する（要手動確認）
  - 実装済み（2026-11-09）: `keyDown` は `classifyKey` で振り分ける（`doCommand(by:)` は何もしない）。Shift+Enter → `ESC CR`、Enter → `\r` はビューのテストで確認済み。Claude Code での手動確認も OK
- [x] 1.3 Option キーによる文字合成と、修飾キーのうち文字合成に使われた分（consumed mods）の扱いを実装する。US 配列で Option+2 → `™` になることをテストで確認する。`kitten show-key -m kitty` で、Ctrl / Alt / Shift / Super × 文字・矢印・Enter が正しく判別されることを確認する（要手動確認）
  - 実装済み（2026-11-09）: `insertText` で届いた文字をキーと一緒にエンコーダに渡す。Option+2 → `™`、kitty の Ctrl+Shift+A → `CSI 97;6u`、離したキーの報告（フラグ 2）はテストで確認済み。keyUp と修飾キー（`flagsChanged`）も送る。Ctrl / Alt / Shift × 文字・矢印・Enter の手動確認も OK
  - 注意: spec（terminal-input）は Command 付きのキーをセッションに送らないので、Super（Command）× キーは `kitten show-key` に届かない（Ctrl / Alt / Shift の組み合わせで確認する）
- [x] 1.4 focus reporting を実装する。ビューの `becomeFirstResponder` / `resignFirstResponder` と、ウィンドウの key 状態の変化で、フォーカスのエンコードを送る。DECSET 1004 を有効にしてアプリを切り替えたときに `ESC[O` と `ESC[I` が届くことを、`cat -v` で確認する（要手動確認）
  - 実装済み（2026-11-09）: first responder とウィンドウの key 状態の変化で `ESC[I` / `ESC[O` を送る（DECSET 1004 が有効で live のときだけ）。コントローラのテストで確認済み。アプリを切り替えたときの手動確認も OK
- [x] 1.5 キー入力を送ったときに viewport を最下部に戻す処理を実装し、テストで確認する

## 2. IME（spec: terminal-input）

- [x] 2.1 `NSTextInputClient` を実装する（`setMarkedText`、`unmarkText`、`insertText`、`hasMarkedText`、`markedRange`、`selectedRange`、`firstRect`、`attributedSubstring`、`validAttributesForMarkedText`）。未確定の文字列は、カーソル位置に重ねて描く
- [x] 2.2 次の手順を手動で確認する（要手動確認）
  - ことえりと Google 日本語入力で、「日本語」と変換して確定すると、`日本語` だけがシェルに届く（Enter が送られない）
  - 変換候補のウィンドウがカーソルの位置に出る
  - Escape で取り消すと、何も送られない
  - 変換中に Backspace を押しても PTY に届かない
  - 絵文字ピッカーで入力できる
  - 確認済み（2026-11-09）: ことえりと Google 日本語入力で、上の 5 項目とも OK（確定した文字列だけが届くこと、変換中の Backspace / Enter を送らないこと、候補のウィンドウの位置の計算は、ビューのテストでも確認済み）

## 3. マウス（spec: terminal-mouse）

- [x] 3.1 マウスエンコーダのラッパーと、座標の変換（ビューの座標 → セル座標 / device pixel 座標）を作る。座標の変換（パディング、Retina）と、SGR 1006 でのクリック → `ESC[<0;10;5M` / `m` をテストで確認する
- [x] 3.2 `mouseDown` / `mouseUp` / `mouseDragged` / `mouseMoved` / `rightMouse*` / `otherMouse*` を実装する（Shift を押しているときと replay 中は報告しない）。any-event のときは tracking area で移動を拾う。`vim` で `:set mouse=a` にして、クリックでカーソルが動くことを確認する（要手動確認）
  - 実装済み（2026-11-09）: 左・右・中・戻る・進むのボタン、ドラッグ、any-event のときの移動（tracking area）。Shift を押しているときは選択、replay 中は送らない。ビューとコントローラのテストで確認済み。`vim` での手動確認も OK
- [x] 3.3 スクロールを実装する（design D5。precise delta の蓄積、マウス報告 → alternate screen なら矢印キー → viewport の順で振り分け）。振り分けの判定と蓄積の計算を純粋関数にしてテストで確認する。viewport を上に動かせるのが最新の `scrollback_lines` 行まで（`VTTerminal.scrollbackRows`）であることもテストで確認する。`less` で矢印キーになること、`htop` でホイールが報告されること、シェルでスクロールバックが見えることを確認する（要手動確認）
  - 実装済み（2026-11-09）: 振り分け（`scrollTarget`）と蓄積（`ScrollAccumulator`）、`scrollback_lines` の上限、less の矢印キー、htop へのホイールの報告、出力が来ても viewport が動かないことはテストで確認済み。`less` / `htop` / シェルでの手動確認も OK

## 4. 選択とコピー（spec: terminal-clipboard）

- [x] 4.1 Phase 0 の対応表を見て、選択をライブラリの API で管理するか、Swift 側で管理するかを決め、design.md D3 に結果を追記する。ドラッグ、ダブルクリック、トリプルクリックの選択を実装する。選択範囲から作ったテキスト（spacer の除外、ソフト折り返しの結合、末尾空白の削除）をテストで確認する
- [x] 4.2 選択範囲の描画（配色ごとの選択色）と、端を越えてドラッグしたときの自動スクロールを実装する。選択色が dark `#264f78`、light `#add6ff` になることを確認する（要手動確認）
  - 実装済み（2026-11-09）: 選択色（dark `#264f78`、light `#add6ff`）はオフスクリーンの描画のテストで確認済み。端を越えたドラッグの自動スクロール（50 ms ごとに 1 行）と選択色の手動確認も OK
- [x] 4.3 Cmd+C（選択が空でも PTY には送らない）、`copy_on_select`、Edit メニュー（Copy / Paste。テキストフィールドにフォーカスがあるときは標準の動作）を実装する。webtabinal `clipboard.test.ts` のうちネイティブにも当てはまるケース（Ctrl / keyup / 変換中は無視する、選択が空のときのコピー、テキストフィールドの判定）を移植して通ることを確認する

## 5. ペーストと OSC 52（spec: terminal-clipboard）

- [x] 5.1 Cmd+V によるテキストのペーストを実装する（ペーストユーティリティで改行を正規化して bracketed paste で囲む。live のときだけ送る）。改行の変換と、2004 が有効なときと無効なときの出力をテストで確認する。`cat -v` で `^[[200~` が付くことを確認する（要手動確認）
  - 実装済み（2026-11-09）: 改行の変換と、2004 が有効なとき / 無効なときの出力はテストで確認済み。`cat -v` での手動確認（`^[[200~` が付くこと、危険なペーストの確認シート）も OK
- [x] 5.2 危険なペーストの確認シートを実装する（キャンセルしたら何も送らない）。判定条件（2004 が無効のときの改行、終了シーケンスが混ざっている）をテストで確認する
- [x] 5.3 OSC 52 の effect を実装する（live の書き込みだけ `NSPasteboard` へ、replay 中の書き込みは破棄、読み取りは常に拒否）。モック WS のテストで、replay 中は pasteboard が変わらないことと、読み取りに応答が返らないことを確認する
- [x] 5.4 Ctrl+V で `0x16` が送られることをテストで確認する

## 6. 完了条件の確認（SPEC §7 Phase 2）

- [x] 6.1 SPEC §7 Phase 2 の完了条件 6 項目（日本語入力、Shift+Enter、¥、vim のマウス、bracketed paste、kitty keyboard protocol）を、まとめて実機で確認する（要手動確認）
  - 確認済み（2026-11-09）: 6 項目とも OK
