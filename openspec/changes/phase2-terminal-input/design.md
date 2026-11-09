# Design: Phase 2 — 入力の完成

## Context

- Phase 1 の時点で、キー入力は `keyDown → キーエンコーダ → TerminalController の入力` という経路で送られている。phase による送信可否の判定と、入力のまとめ送りは `TerminalController` が受け持っている。
- 置き換え元の Web 版の挙動（webtabinal `6dca08f`）:
  - **キー処理の順序**（`TerminalView.tsx` のカスタムキーハンドラ）:
    1. Shift+Enter
    2. `¥`
    3. Cmd+C / Cmd+V
    4. それ以外は xterm に渡す
  - **Shift+Enter**: keydown のときだけ反応する。条件は `key === 'Enter'` かつ Shift あり、Ctrl / Alt / Meta なし、変換中（`keyCode 229` を含む）ではないこと。
  - **`¥`**: keydown のときだけ反応する。条件は `key === '¥'` かつ Ctrl / Alt / Meta なし（Shift は可）、変換中ではないこと。
  - **Cmd+C**: 選択が空でも「処理済み」として扱い、PTY には送らない。
  - **Cmd+V（デスクトップ版）**: 画像（PNG / TIFF）を優先し、無ければ文字列を貼る。画像の処理は Phase 4 で扱う。
  - **Ctrl+V**: 横取りしない（`0x16` がそのまま PTY に送られる）。
  - **`copy_on_select`**: 選択が変わるたびに書き込む。既定は false。
  - **Option キー**: xterm.js の `macOptionIsMeta` は既定の false のまま。
  - **ホイール**: xterm.js の既定の挙動で、alternate screen かつマウス報告が無効なら矢印キーに変換される。
- 該当するテスト: `web/tests/terminal-input.test.ts`（12 件）、`clipboard.test.ts`（8 件）。

## Goals / Non-Goals

**Goals:**

- SPEC §7 Phase 2 の完了条件をすべて満たす。
  - IME の候補ウィンドウがカーソルの位置に出る。
  - Shift+Enter で改行できる。
  - `¥` で `\` が入る。
  - vim でマウスを使える。
  - bracketed paste が効く。
  - kitty keyboard protocol が使える。
- キー入力がどの順で判定されるかを 1 か所にまとめ、Phase 3 のコード（Ctrl+J のプレフィックス）を差し込める形にしておく。

**Non-Goals:**

- 画像のペーストとドロップ（Phase 4）。
- ハイパーリンクの Cmd+クリック（Phase 5）。
- 検索（Phase 5）。
- 設定画面から `shift_enter_newline` と `copy_on_select` を変更する機能（Phase 4）。Phase 2 では、起動時に config から読む。

## Decisions

### D1. キーイベントの処理経路を 1 本にまとめる

`TerminalView.keyDown(with:)` で、上から順に判定する。

```
0. （Phase 3 で追加）コードのプレフィックス判定 → 処理したら終了
1. hasMarkedText()                       → interpretKeyEvents に渡す（IME が処理する）
2. Command を含む                          → super（メニューのキー等価物。PTY には送らない）
3. Shift+Enter の条件に一致                 → "\x1b\r"
4. `¥` の条件に一致                         → "\\"
5. Control を含む、または文字以外のキー        → キーエンコーダに直接渡す（Ctrl+V → 0x16 もここ）
6. それ以外                                → interpretKeyEvents に渡す
                                           → insertText でテキストを付けてキーエンコーダへ
                                             （IME と、Option で合成された文字もここを通る）
```

- 判定の条件は、`NSEvent` から取り出した値型の `KeyInput`（`characters`、`charactersIgnoringModifiers`、`keyCode`、`modifierFlags`、`isComposing`）を受け取る純粋関数 `classifyKey(_:settings:) -> KeyAction` にまとめる。これで AppKit 無しでもテストできる。`terminal-input.test.ts` のケースは、ここに移植する。
- Ctrl+文字を `interpretKeyEvents` に渡すと、`insertNewline:` などのセレクタに変換されてしまう。そのため 5 でキーエンコーダに直接渡す。
- `doCommand(by:)` で来るセレクタは無視する。キーエンコーダに渡すのは keyDown 側だけにする。
- 参考にする実装: Ghostty 本体の macOS 版の `SurfaceView_AppKit.swift`（キーの変換、修飾キーのうち文字合成に使われた分（consumed mods）の扱い、IME）。

### D2. IME（`NSTextInputClient`）

- `setMarkedText` で受け取った未確定の文字列は、`TerminalView` の状態として持つ。描画するときに、カーソルのセルから、背景を塗って下線付きで重ねて描く。Terminal には書き込まない。
- `insertText`（確定）が来たら、`classifyKey` を通さずにテキストとして送る（`¥` の書き換えはしない）。
- `firstRect(forCharacterRange:actualRange:)` は、カーソルのセルの矩形をスクリーン座標に変換して返す。未確定の文字列がある場合は、その末尾の位置を返す。
- 変換中の Enter / Escape / Backspace は IME が消費するので、PTY には送らない（D1 の 1 で処理する）。

### D3. マウスと選択

- **マウス報告**: Terminal のマウスモードが有効で、かつ Shift が押されていなければ、マウスエンコーダに渡す。
  - 座標は、ビューの座標からパディングを引き、セル座標と device pixel 座標の両方を求める。
  - ボタン、修飾キー、ドラッグ、移動（any-event のときだけ）を扱う。
- **選択**:
  - 選択はライブラリの選択機能で管理する（Phase 0 の対応表で、あることを確認済みであることが前提）。ライブラリに無い場合は、RenderState のセル座標を使って Swift 側で範囲を管理し、テキストに変換するときに plain フォーマッタの範囲指定を使う。
  - ダブルクリックは単語、トリプルクリックは行を選択する。単語の区切り文字は libghostty の既定値に従う。
  - ドラッグが上下の端を越えたら、タイマーで viewport を自動スクロールする。
- **copy on select**: マウスを離した時点で選択が空でなければコピーする。Web 版は選択が変わるたびに書き込むが、利用者から見える結果は同じになる。

### D4. ペースト

- テキストの変換（改行の正規化、bracketed paste で囲む、危険かどうかの判定）は、libghostty のペーストユーティリティを使う。
- 危険と判定されたときは、`NSAlert` のシートで確認する。メッセージは「貼り付けるテキストに改行が含まれ、そのまま実行される可能性があります」。
- Web 版にはこの確認が無いので、ここは Web 版との差分になる。ただし SPEC §5.1 の指定であり、zsh や bash は既定で bracketed paste を有効にしているので、確認が出るのはまれ。

### D5. スクロール

- `scrollWheel(with:)` では、`hasPreciseScrollingDeltas` のときはピクセル量を蓄積し、セルの高さごとに 1 行として換算する。それ以外のときは、行数をそのまま使う。
- 振り分けは spec の順序どおり（マウス報告 → alternate screen なら矢印キー → viewport）。矢印キーのシーケンスはキーエンコーダで作るので、application cursor mode にも従う。
- viewport を動かしたら、その範囲を全部 dirty にして再描画する。新しい出力があっても viewport は動かさない（ライブラリの既定に従う。違っていたら Swift 側で位置を保持する）。

### D6. OSC 52 と effect

Phase 1 の effect の表に、次の行を追加する。

| effect | `.replaying` | `.live` |
|---|---|---|
| クリップボードへの書き込み | 破棄 | `NSPasteboard` に書く |
| クリップボードの読み取り | 拒否 | 拒否（応答しない） |

### D7. config の扱い

- `shift_enter_newline`（既定 true）と `copy_on_select`（既定 false）は、`DaemonConfig` に起動時に読み込む。
- Phase 4 で、設定画面で変えたときに即時に反映されるようにする。そのため、値は `@MainActor` のストア経由で参照する形にしておく。

## Risks / Trade-offs

- **[Risk] `NSTextInputClient` は実装量が多く、細かいバグが出やすい**（SPEC §9）。→ Ghostty 本体の実装を参考にする。手動テストのチェックリストを tasks に含める（ことえり、Google 日本語入力、絵文字ピッカー、変換中の Backspace）。
- **[Risk] ライブラリに選択の API が無い。** → D3 の代わりの方法（Swift 側で範囲を管理する）で進める。この判断は Phase 0 の対応表を見て、タスクの最初に行う。
- **[Risk] 修飾キーの扱い（consumed mods）を間違えると、kitty keyboard protocol の報告がずれる。** → `kitten show-key -m kitty` で、主要な組み合わせ（Ctrl / Alt / Shift / Super × 文字・矢印・Enter）を手動で確認する。
- **[Trade-off] Shift+Enter をキーエンコーダより前で横取りするので、kitty keyboard protocol を有効にしたアプリにも Shift+Enter の本来のコードは届かない。** → Web 版と同じ挙動で、Claude Code が期待している動作でもある。`shift_enter_newline` を false にすれば回避できる。
