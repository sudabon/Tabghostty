# TerminalCore

libghostty-vt（C API）の Swift ラッパー。

- 出典は libghostty-vt **1.0.0**（`scripts/libghostty.lock` でピン留め）の `Vendor/GhosttyVt.xcframework/macos-arm64_x86_64/Headers/ghostty/vt.h` と `ghostty/vt/*.h` である。下の表で「ヘッダ」列に書いたパスは、`ghostty/vt/` からの相対パス。
- 実装では、この表にある名前だけを使う。表に無い機能が必要になったら、ヘッダを読んで表に追記してから使う。
- Swift からは `import GhosttyVt` で使う。XCFramework 同梱の modulemap が `module GhosttyVt { umbrella header "ghostty/vt.h" }` を宣言している。

## 共通の規約

| 項目 | 内容 | ヘッダ |
|---|---|---|
| 戻り値 | 失敗しうる関数は `GhosttyResult` を返す。値は `GHOSTTY_SUCCESS`(0) / `GHOSTTY_OUT_OF_MEMORY` / `GHOSTTY_INVALID_VALUE` / `GHOSTTY_OUT_OF_SPACE`（バッファ不足。`out_written` に必要量が入る）/ `GHOSTTY_NO_VALUE` / `GHOSTTY_UNSUPPORTED`（このビルドで無効な機能、未知のキー） | `types.h` |
| ハンドル | `GhosttyTerminal` などは不透明ポインタ。`*_new(allocator, &out, …)` で作り、`*_free` で解放する | `types.h` |
| アロケータ | `const GhosttyAllocator*` は `NULL` で既定のアロケータになる。`*_alloc` 系の関数が返すバッファは、`ghostty_free(allocator, ptr, len)` に同じアロケータを渡して解放する | `allocator.h` |
| 文字列 | 受け渡しは `GhosttyString { const uint8_t* ptr; size_t len; }` で行う。callback に渡されるものは、callback の間だけ有効 | `types.h` |
| サイズ付き構造体 | `size` フィールドを持つ構造体は、`GHOSTTY_INIT_SIZED(type)` または `ghostty_sized_init(ptr, size)` で初期化する | `types.h` |
| バージョン | `GHOSTTY_VT_VERSION`（コンパイル時。常に 3 つの数字）と `ghostty_version()`（実行時。開発版なら `1.1.0-dev+abc1234` のような形）。機能が有効かどうかは `ghostty_build_info` で確かめる。Phase 6 では `ghostty_version()` を `GhosttySystem.libraryVersion` で読み、デーモンが生成した画面のバージョンと照合する | `version.h`, `build_info.h` |
| **スレッド** | ハンドルはスレッドセーフではない。同じ Terminal に対する書き込み、描画（RenderState の更新）、検索、圧縮は、利用側で直列化する（`terminal.h` の `ghostty_terminal_compress` の注記）。スレッドセーフと明記されているのは、純粋関数の `ghostty_unicode_*` と、`ghostty_search_tick`（コピー済みのデータだけを扱い、Terminal を読まないので、別のスレッドが Terminal を変更していても呼べる）。`ghostty_sys_set` は、ほかのスレッドがライブラリを使い始める前に呼ぶ | `terminal.h`, `unicode.h`, `search.h`, `sys.h` |
| **再入** | effect の callback は `ghostty_terminal_vt_write()` の中で同期的に呼ばれる。callback の中から同じ Terminal に `vt_write` / `vt_write_until` を呼んではならない（チェックもエラー報告も無い）。callback では値をキューに積むだけにする | `terminal.h`（`ghostty_terminal_set` の注記） |

## SPEC §3 の概念と C API の対応

「Go 名」の列には SPEC.md §3 での表記（Go バインディング `go.mitchellh.com/libghostty` の概念名）を書いている。

### Terminal

| 概念 | Go 名 | C 関数・型 | ヘッダ | 備考 |
|---|---|---|---|---|
| 生成 | Terminal | `ghostty_terminal_new(allocator, &terminal, cols, rows)` | `terminal.h` | Phase 0 |
| 解放 | Terminal.Close | `ghostty_terminal_free(terminal)` | `terminal.h` | Phase 0 |
| 書き込み | Terminal.Write | `ghostty_terminal_vt_write(terminal, data, len)` | `terminal.h` | 戻り値なし。チャンクの境界がシーケンスの途中でもよい。Phase 0 |
| 境界で止める書き込み | — | `ghostty_terminal_vt_write_until(…, boundaries, &stop)` | `terminal.h` | APC / DCS / OSC の境界や GROUND で止められる。Phase 5 では使わない（`ghostty_terminal_vt_write` はシーケンスの途中で区切ってよいので、64 KiB ずつに区切って書く。phase5 design D2） |
| リサイズ | Terminal.Resize | `ghostty_terminal_resize(terminal, cols, rows, cell_width_px, cell_height_px)` | `terminal.h` | セルのピクセルサイズも同時に渡す。render hold も解除される。Phase 1 |
| リセット | Terminal.Reset | `ghostty_terminal_reset(terminal)` | `terminal.h` | 完全リセット（RIS 相当）。Phase 1 |
| 設定 / effect の登録 | Terminal options | `ghostty_terminal_set(terminal, GhosttyTerminalOption, value)` | `terminal.h` | `NULL` を渡すと既定値に戻る。effect の一覧は後述 |
| 状態の取得 | — | `ghostty_terminal_get` / `ghostty_terminal_get_multi`（`GHOSTTY_TERMINAL_DATA_*`） | `terminal.h` | 次のような値を取れる: COLS / ROWS、CURSOR_*、ACTIVE_SCREEN、KITTY_KEYBOARD_FLAGS、MOUSE_TRACKING、SCROLLBAR、SELECTION、MODE、TITLE、PWD、MOUSE_SHAPE、MEMORY_USAGE、VIEWPORT_ACTIVE、TOTAL_ROWS、SCROLLBACK_ROWS（`size_t`。Phase 1 でスクロールバックの行数に使う） |
| viewport のスクロール | — | `ghostty_terminal_scroll_viewport(terminal, GhosttyTerminalScrollViewport)` | `terminal.h` | TOP / BOTTOM / DELTA（上が負）/ ROW / DELTA_PROMPT（OSC 133 が必要）。Phase 2 |
| 最大スクロールバック | max scrollback | `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES`（`size_t*`）と `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES`（`size_t*`） | `terminal.h` | **既定ではバイト数の上限が 10,000 バイト**（実際には 1 ページ、約 400 KB）で、行数の上限は無い。`scrollback_lines` を反映するには、`MAX_BYTES = SIZE_MAX` にしたうえで `MAX_LINES` を設定する。削除はページ単位なので、実際に残る行数は設定値より多くなる。いつでも変えられるので、Phase 4 では `scrollback_lines` の変更を作成済みの Terminal にも反映する（`TerminalController.setMaxScrollback`） |
| セル / 行の参照 | — | `ghostty_terminal_grid_ref` / `ghostty_grid_ref_cell` / `_row` / `_graphemes` / `_style` / `_hyperlink_uri` | `terminal.h`, `grid_ref.h` | 参照は次に Terminal を変更するまでしか有効でない。変更を越えて追跡するなら `ghostty_terminal_grid_ref_track`（`grid_ref_tracked.h`）。Phase 5 では `_hyperlink_uri`（OSC 8 の URI。無ければ長さ 0）と `_row` + `ghostty_row_get(GHOSTTY_ROW_DATA_WRAP)`（ソフト折り返し）でリンクを探す。Phase 6 の `ScreenNormalizer` は、`GHOSTTY_POINT_TAG_ACTIVE`（`point.h`）の座標で `_cell` + `ghostty_cell_get(GHOSTTY_CELL_DATA_WIDE)` と `_graphemes`（コードポイントの配列。結合文字を含む）を読む。RenderState の更新と違って Terminal の dirty を消費しないので、描画中の端末でも使える |
| 参照から座標へ | — | `ghostty_terminal_point_from_grid_ref(terminal, &ref, GHOSTTY_POINT_TAG_*, &coordinate)` | `terminal.h`, `point.h` | 参照の座標系に入らなければ `GHOSTTY_NO_VALUE`。Phase 5 の検索で、一致の位置を画面の座標（`SCREEN`。スクロールバックの先頭が 0 で、`GHOSTTY_TERMINAL_DATA_SCROLLBAR` の `offset` と同じ座標）にする |
| 行の属性 | — | `ghostty_row_get(row, GHOSTTY_ROW_DATA_*, &value)`（`WRAP` / `WRAP_CONTINUATION` / `HYPERLINK` など） | `screen.h` | RenderState の行は `GHOSTTY_RENDER_STATE_ROW_DATA_RAW` で `GhosttyRow` を取る。Phase 5 でスナップショットに折り返しを入れる（`FrameSnapshot.wrappedRows`） |
| スクロールバックの圧縮 | — | `ghostty_terminal_compress` / `ghostty_terminal_compression_activity` | `terminal.h` | アイドル時に INCREMENTAL で呼ぶ。Phase 5 のメモリ対策の候補 |

### effect（`ghostty_terminal_set` で callback を登録する）

すべての callback は、`GHOSTTY_TERMINAL_OPT_USERDATA` で設定した `void* userdata` を受け取る。Swift からは `@convention(c)` の関数と `Unmanaged` の userdata で受ける。

| effect | Go 名 | オプション / callback の型 | 備考（Tabghostty での扱い） |
|---|---|---|---|
| PTY への書き戻し（DA / DSR / サイズ報告 / モード問い合わせ / kitty の応答） | WritePty | `GHOSTTY_TERMINAL_OPT_WRITE_PTY` / `GhosttyTerminalWritePtyFn(terminal, userdata, data, len)` | `data` は callback の間だけ有効なので、コピーしてキューに積む。live のときだけ `input` で送る（Phase 1） |
| ベル | Bell | `GHOSTTY_TERMINAL_OPT_BELL` / `GhosttyTerminalBellFn` | 登録してキューに積み、`TerminalController` で捨てる（Phase 1 の決定。音も Dock も鳴らさない） |
| タイトルの変更 | TitleChanged | `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` / `GhosttyTerminalTitleChangedFn` | 新しい値は `GHOSTTY_TERMINAL_DATA_TITLE` で読む。登録してキューに積み、捨てる（タブ名はデーモンの cwd / command から作る） |
| 作業ディレクトリの変更（OSC 7 / 9 / 1337 CurrentDir） | — | `GHOSTTY_TERMINAL_OPT_PWD_CHANGED` / `GhosttyTerminalPwdChangedFn` | 使わない（cwd はデーモンから受け取る） |
| クリップボードへの書き込み（OSC 52 / OSC 1337 Copy / OSC 5522） | Clipboard write | `GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE` / `GhosttyTerminalClipboardWriteFn`（`GhosttyClipboardWriteReplyFn` で結果を返す）。上限は `GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES` | live のときだけ `NSPasteboard` に書く（Phase 2） |
| クリップボードの読み取り（OSC 52 `?`） | Clipboard read | `GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ` / `GhosttyTerminalClipboardReadFn`（`GhosttyClipboardReadReplyFn`） | 同期的に呼ばれ、callback の中で応答しなければならない。常に拒否する（Phase 2） |
| デスクトップ通知（OSC 9 / OSC 777） | Desktop notification | `GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION` / `GhosttyTerminalDesktopNotificationFn`（`GhosttyTerminalDesktopNotification` の title / body は callback の間だけ有効） | 登録してキューに積み、捨てる（Phase 1）。通知はデーモンの `notify` に任せる。OSC 99 は libghostty が扱わない |
| 進捗報告（OSC 9;4） | Progress report | `GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT` / `GhosttyTerminalProgressReportFn` | 登録しない |
| セマンティックプロンプト（OSC 133） | Semantic prompt | `GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT` / `GhosttyTerminalSemanticPromptFn` | 任意。プロンプトの間を移動する機能に使える |
| render hold（同期出力 DECSET 2026） | — | `GHOSTTY_TERMINAL_OPT_RENDER_HOLD` / `GhosttyTerminalRenderHoldFn(…, bool held)` | 開始と終了が必ず対で呼ばれる。リサイズとリセットでも解除される。Phase 5 で登録し（`VTTerminal.isRenderHeld`）、保留している間は描画しない。タイムアウトはライブラリに無いので、`TerminalController` が 1 秒を持つ |
| **サイズの問い合わせ（XTWINOPS `CSI 14/16/18/19 t`）** | — | `GHOSTTY_TERMINAL_OPT_SIZE` / `GhosttyTerminalSizeFn`（bool を返す） | **未設定（NULL）だと問い合わせを黙って無視する**。Phase 1 の「セルのピクセルサイズを報告する」には、この callback を登録し、`ghostty_terminal_resize` に渡したのと同じ値を返す必要がある |
| 一次 / 二次 DA（`CSI c` など） | — | `GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES` / `GhosttyTerminalDeviceAttributesFn` | NULL なら、ライブラリの既定値（ANSI カラー付きの VT220）で応答する。登録しない |
| XTVERSION（`CSI > q`） | — | `GHOSTTY_TERMINAL_OPT_XTVERSION` / `GhosttyTerminalXtversionFn` | NULL なら `libghostty` と応答する。登録しない |
| 配色の問い合わせ（`CSI ? 996 n`） | — | `GHOSTTY_TERMINAL_OPT_COLOR_SCHEME` / `GhosttyTerminalColorSchemeFn` | NULL なら無視する。Phase 4 で、解決済みの配色を返すように登録してもよい |
| ENQ（0x05） | — | `GHOSTTY_TERMINAL_OPT_ENQUIRY` / `GhosttyTerminalEnquiryFn` | NULL なら応答しない。登録しない |
| その他 | — | `OPT_TITLE_REPORT`（既定で無効）、`OPT_PROGRAM_STATUS`（NULL なら応答しない）、`OPT_RESIZE_WINDOW` / `OPT_RESET` / `OPT_UNKNOWN_SEQUENCE`（NULL なら無視する） | 登録しない。必要になったら、その Phase で追記する |
| 既定の色 | — | `OPT_COLOR_FOREGROUND` / `_BACKGROUND` / `_CURSOR`（`GhosttyColorRgb*`）/ `_PALETTE`（`GhosttyColorRgb[256]`） | Tabghostty の配色を設定する（Phase 1）。OSC 10/11/12 には、デーモンが応答する。`ghostty_terminal_reset` の後も残るが、念のため attach のたびに設定し直す。Phase 4 では、配色を切り替えたときにも設定し直す（`TerminalController.setColors`） |
| 既定のカーソル | — | `GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE`（`GhosttyCursorStyle*`）/ `GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK`（`bool*`） | DECSCUSR 0 で戻る形と点滅。Phase 1 で「点滅するブロック」にする（xterm.js の `cursorBlink: true` と同じ） |
| Kitty Graphics の設定 | — | `OPT_KITTY_IMAGE_STORAGE_LIMIT` / `_MEDIUM_FILE` / `_MEDIUM_TEMP_FILE` / `_MEDIUM_SHARED_MEM`、`OPT_APC_MAX_BYTES(_KITTY)` | Phase 5 で保存領域の上限を 64 MB にする（既定の 10 MB では、RGBA に展開した Retina のスクリーンショットが入らない）。ファイル・一時ファイル・共有メモリでの転送は既定のまま無効（直接の転送だけ） |

### RenderState（描画）

| 概念 | Go 名 | C 関数・型 | ヘッダ | 備考 |
|---|---|---|---|---|
| 生成 / 解放 | RenderState | `ghostty_render_state_new` / `ghostty_render_state_free` | `render.h` | Phase 1 |
| 更新 | RenderState.Update | `ghostty_render_state_update(state, terminal)`、または `_begin_update` と `_end_update` | `render.h` | Terminal を使うのは更新している間だけ。更新後のデータは Terminal とは独立して読める |
| dirty | — | `GHOSTTY_RENDER_STATE_DATA_DIRTY`（`FALSE` / `PARTIAL` / `FULL`）、行の `GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY`、`ghostty_render_state_row_iterator_next_dirty`、`ghostty_render_state_clean`、全体を描き直させる `ghostty_render_state_set(GHOSTTY_RENDER_STATE_OPT_DIRTY, &FULL)` | `render.h` | 描画したら `clean` する |
| 行 | — | `ghostty_render_state_row_iterator_new` / `_next` / `ghostty_render_state_row_get`（`ROW_DATA_CELLS` / `SELECTION` / `VIEWPORT_Y` / `ID`） | `render.h` | |
| セル | — | `ghostty_render_state_row_cells_new` / `_next` / `_select(x)` / `ghostty_render_state_row_cells_get`（`RAW` / `STYLE` / `GRAPHEMES_LEN` / `GRAPHEMES_BUF` / `GRAPHEMES_UTF8`（`GhosttyBuffer`。足りなければ `GHOSTTY_OUT_OF_SPACE` と必要な長さ）/ `BG_COLOR` / `FG_COLOR` / `SELECTED` / `HAS_STYLING`） | `render.h` | wide 文字かどうかと幅は、`RAW` のセルから `ghostty_cell_get`（`screen.h`）で読む |
| スタイル | — | `GhosttyStyle`、`ghostty_style_default` / `ghostty_style_is_default` | `style.h` | |
| 色 | — | `GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND` / `_FOREGROUND` / `_CURSOR` / `_PALETTE` / `COLORS`、`ghostty_color_rgb_get`、`ghostty_color_contrast` / `ghostty_color_luminance` | `render.h`, `color.h` | コントラストの補正（Phase 1）に `ghostty_color_contrast` が使える |
| カーソル | — | `GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE` / `_VISIBLE` / `_BLINKING` / `_VIEWPORT_X` / `_VIEWPORT_Y` / `_VIEWPORT_WIDE_TAIL` / `_PASSWORD_INPUT`、まとめて取る `GHOSTTY_RENDER_STATE_DATA_CURSOR`（`GhosttyRenderStateCursor`。サイズ付き構造体） | `render.h` | |
| オーバースキャン | — | `GHOSTTY_RENDER_STATE_OPT_OVERSCAN`、`DATA_OVERSCAN` | `render.h` | スムーズスクロールに使える（任意） |
| 画像の配置 | — | `ghostty_render_state_image_iterator_new` / `_next` / `ghostty_render_state_image_get`（`PROTOCOL` / `IMAGE_ID` / `IMAGE_GENERATION` / `LAYER` / `Z` / `VIEWPORT_COL` / `VIEWPORT_ROW` / `CELL_OFFSET_X/Y` / `PIXEL_WIDTH/HEIGHT` / `SOURCE_X/Y/WIDTH/HEIGHT`）、`DATA_IMAGE_ITERATOR` / `DATA_IMAGE_PLACEMENTS_GENERATION` | `render.h`, `types.h` | Phase 5。iterator の順は描く順ではないので、層（`GhosttyImageLayer`）と z で並べ替える。世代はほかの画像・端末とも重ならないので、テクスチャのキャッシュのキーに使う |

### 入力のエンコード

| 概念 | Go 名 | C 関数・型 | ヘッダ | 備考 |
|---|---|---|---|---|
| キーエンコーダ | KeyEncoder | `ghostty_key_encoder_new` / `_free` / `_set`（`OPT_CURSOR_KEY_APPLICATION` / `OPT_KEYPAD_KEY_APPLICATION` / `OPT_ALT_ESC_PREFIX` / `OPT_KITTY_FLAGS` / `OPT_MACOS_OPTION_AS_ALT` / `OPT_BACKARROW_KEY_MODE`）/ `_set_from_terminal(encoder, terminal)` / `_encode(encoder, event, buf, len, &written)` | `key/encoder.h` | 送る前に `_set_from_terminal` で Terminal のモードを反映する。Phase 1 / 2 |
| キーイベント | — | `ghostty_key_event_new` / `_free` / `_set_action` / `_set_key`（`GhosttyKey`）/ `_set_mods` / `_set_consumed_mods` / `_set_composing` / `_set_utf8` / `_set_unshifted_codepoint` | `key/event.h`, `key.h` | 修飾キーのうち文字合成に使われた分（consumed mods）は `_set_consumed_mods` で渡す（Phase 2） |
| マウスエンコーダ | MouseEncoder | `ghostty_mouse_encoder_new` / `_free` / `_set`（`OPT_EVENT` / `OPT_FORMAT` / `OPT_SIZE` / `OPT_ANY_BUTTON_PRESSED` / `OPT_TRACK_LAST_CELL`）/ `_set_from_terminal` / `_reset` / `_encode` | `mouse/encoder.h` | Phase 2。`_set_from_terminal` だけでなく、`OPT_SIZE` と `OPT_ANY_BUTTON_PRESSED` を設定し直しても、同じセルへの移動を省く記録（`TRACK_LAST_CELL`）が消える（2026-11-09 の計測）。値が変わったときだけ設定する |
| マウスイベント | — | `ghostty_mouse_event_new` / `_set_action` / `_set_button` / `_clear_button` / `_set_mods` / `_set_position`（`GhosttyMousePosition`） | `mouse/event.h`, `mouse.h` | |
| フォーカス | focus encoding | `ghostty_focus_encode(GHOSTTY_FOCUS_GAINED / GHOSTTY_FOCUS_LOST, buf, len, &written)` | `focus.h` | DECSET 1004 が有効かどうかは `GHOSTTY_TERMINAL_DATA_MODE` で確かめる。Phase 2 |
| ペースト | paste utilities | `ghostty_paste_is_safe(data, len)` / `ghostty_paste_encode(data, len, bracketed, buf, len, &written)` / `ghostty_terminal_paste(terminal, &GhosttyPaste, &pasted)` | `paste.h` | 危険なペーストの判定と bracketed paste は、これで行う（Phase 2） |
| モード | — | `GhosttyMode`、`GHOSTTY_TERMINAL_DATA_MODE`、`ghostty_mode_report_encode` | `modes.h` | 例: `GHOSTTY_MODE_SYNCHRONIZED_OUTPUT`（2026） |
| サイズ報告 | — | `ghostty_size_report_encode` | `size_report.h` | 単体のエンコーダ。Terminal の応答は `GHOSTTY_TERMINAL_OPT_SIZE` の callback 経由で行う（effect の表を参照） |

### 選択・検索・フォーマッタ

| 概念 | Go 名 | C 関数・型 | ヘッダ | 備考 |
|---|---|---|---|---|
| 選択（範囲） | Selection | `GhosttySelection`、`GHOSTTY_TERMINAL_OPT_SELECTION` / `GHOSTTY_TERMINAL_DATA_SELECTION`、`ghostty_terminal_selection_adjust` / `_order` / `_ordered` / `_contains` / `_equal` | `selection.h`, `terminal.h` | Terminal を変更したら無効になる |
| 選択（ジェスチャー） | — | `ghostty_selection_gesture_new` / `_free` / `_reset` / `_get` と `ghostty_selection_gesture_event_new` / `_set` / `ghostty_selection_gesture_event` | `selection.h` | ドラッグ、ダブルクリック、トリプルクリックをライブラリ側で解釈する。Phase 2 の design D3 で「ライブラリ側の選択」を採用できる |
| 単語 / 行 / 全体 / 出力の選択 | — | `ghostty_terminal_select_word` / `_select_word_between` / `_select_line` / `_select_all` / `_select_output` | `selection.h` | `select_output` は OSC 133 が前提 |
| 検索 | Search | `ghostty_search_new(allocator, &search, terminal)` / `_free` / `_set`（needle など）/ `_feed` / `_tick` / `_run` / `_select_next` / `_select_prev` / `_get` | `search.h` | primary と alternate の両方の画面とスクロールバックが対象（アクティブな画面の結果を返す）。Terminal を読むのは `feed` のときだけで、`tick` は Terminal に触れない。大文字小文字を区別しないのは ASCII の英字だけ。Phase 5 では `_run` で一度に検索し、`GHOSTTY_SEARCH_DATA_MATCHES`（新しいものから）を読む。`scrollback_lines` より古い行の一致を除くため、一致の選択と viewport の移動は Swift 側で行う（`GHOSTTY_SEARCH_OPT_SELECT_SCROLL` は `NONE`） |
| フォーマッタ | Formatter | `ghostty_formatter_terminal_new(allocator, &formatter, terminal)` / `_set` / `_get` / `_format_alloc` / `_format_buf` / `_format`（`GhosttyWriter`）/ `_free` | `formatter.h` | Terminal はフォーマッタより長く生きていなければならない。既定は PLAIN で、`UNWRAP = false`、`TRIM = true` |
| 出力形式 | plain / VT / HTML | `GHOSTTY_FORMATTER_OPT_EMIT` = `GHOSTTY_FORMATTER_FORMAT_PLAIN` / `_VT` / `_HTML`。VT のときの追加情報は `OPT_EXTRAS` | `formatter.h`, `types.h` | コピー用のテキストは、PLAIN で `UNWRAP` と `TRIM` を両方 true にし、`OPT_SELECTION` で範囲を指定する（Ghostty 本体と同じ） |

### Kitty Graphics / Snapshot / その他

| 概念 | Go 名 | C 関数・型 | ヘッダ | 備考 |
|---|---|---|---|---|
| Kitty Graphics の取得 | Kitty graphics | `GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS` → `GhosttyKittyGraphics`、`ghostty_kitty_graphics_get` / `_image(graphics, id)` / `_image_get`（`WIDTH` / `HEIGHT` / `FORMAT` / `PIXELS` / `GENERATION`） | `kitty_graphics.h` | Phase 5。中身は展開済みの RGB / RGBA / グレー / グレーと alpha（PNG は送られた時点で RGBA に展開される）。保存領域とポインタは、次に Terminal を変更するまでしか有効でない |
| 配置 | — | `ghostty_kitty_graphics_placement_iterator_new` / `_set` / `_next` / `_get` / `_rect` / `_pixel_size` / `_grid_size` / `_viewport_pos` / `_source_rect` / `_render_info` | `kitty_graphics.h` | |
| アニメーション | — | `ghostty_kitty_graphics_animation_tick(graphics, now_ms, &next_ms)` | `kitty_graphics.h` | |
| Snapshot のエンコード | Snapshot | `ghostty_snapshot_encode(terminal, writer)` / `_encode_buf` / `_encode_alloc` | `snapshot.h` | writer の callback の中で、同じ Terminal の API を呼んではならない。パーサがシーケンスや UTF-8 の途中にあるときは、`GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` を書き込みの前から有効にしておかないと `GHOSTTY_INVALID_VALUE` になる。バイト形式は ABI の約束の対象外。Phase 6 の ADR（`docs/adr/0001-snapshot-replay.md`）で検討し、今は使わないことにした（計測は `SnapshotReplayMeasurementTests`） |
| Snapshot のデコード | — | `ghostty_snapshot_decoder_new` / `_new_buf` / `_set` / `_ready` / `_next` / `_decode` / `_get` / `_free` | `snapshot.h` | 少しずつ進めながら復元できる。`_decode` / `_ready` が返す Terminal は呼び出し側が `ghostty_terminal_free` で解放する。`GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY` で、復元しながらスクロールバックを圧縮できる |
| 継続（continuation） | — | `ghostty_terminal_continuation_write` / `_buf` / `_alloc`、`GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` | `terminal.h` | 書きかけのシーケンスを別の Terminal に引き継ぐのに使う |
| Unicode の幅 | — | `ghostty_unicode_codepoint_width` / `ghostty_unicode_grapheme_width` | `unicode.h` | スレッドセーフ |
| OSC / SGR パーサ | OSC / SGR parser | `ghostty_osc_*` / `ghostty_sgr_*` | `osc.h`, `sgr.h` | 単体で使う部品。Terminal が内部で処理するので、Tabghostty では使わない見込み |
| ログ | — | `ghostty_sys_set(GHOSTTY_SYS_OPT_…)`、`ghostty_sys_log_stderr` | `sys.h` | ほかのスレッドがライブラリを使い始める前に設定する |
| PNG の展開 | — | `ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, fn)` / `GhosttySysDecodePngFn(userdata, allocator, data, len, GhosttySysImage*)`、`ghostty_alloc` / `ghostty_free` | `sys.h`, `allocator.h` | **libghostty-vt は PNG を自分では展開しない**。渡さないと Kitty Graphics の `f=100`（`kitten icat` が使う）は捨てられる。Phase 5 で ImageIO による展開を渡す（`GhosttySystem.install()`。アプリの起動時と、最初の `VTTerminal` を作るとき）。出力は straight alpha の RGBA8 で、バッファは渡されたアロケータで確保する |

## SPEC §9 の未確定事項の調査結果

| 項目 | 結果 | 影響 |
|---|---|---|
| Sixel | **なし**。描画も解釈もしない。ヘッダにある Sixel の記述は、DA の機能番号 `GHOSTTY_DA_FEATURE_SIXEL`（`device.h`）だけ | Phase 5 の spec（inline-images）のとおり対応外とする。Phase 7 で README の対応表から外す |
| iTerm2 IIP（OSC 1337 File） | **なし**。OSC 1337 で扱うのは `Copy`（クリップボードへの書き込み）と `CurrentDir`（作業ディレクトリ）だけ | 同上 |
| C API の正確な名前 | この表のとおり | Phase 1 以降は、この表の名前を使う |
| スクロールバックの上限 | 既定はバイト数での上限（10,000 バイト、実際には 1 ページ）で、行数の上限は無い。行数の上限を設定しても削除はページ単位なので、2026-11-09 の計測では「上限 100 行・80 列で 500 行を流すと 477 行残る」 | Phase 1 で `MAX_BYTES = SIZE_MAX` と `MAX_LINES = scrollback_lines` を設定する。利用者に見せる行数は `VTTerminal.scrollbackRows` で上限に丸める（spec は「見せる行数が上限まで」。スクロール・検索・テキストの取り出しも、この値で範囲を丸める。phase1 の design D2） |
| サイズの問い合わせへの応答 | `GHOSTTY_TERMINAL_OPT_SIZE` を登録しないと、`CSI 14/16/18/19 t` は無視される | Phase 1 でこの callback を登録する（phase1 の design D2 に追記済み） |

### SPEC が想定していなかったが C API にある機能

| 機能 | API | 使える場面 |
|---|---|---|
| 選択のジェスチャー（ドラッグ、ダブルクリック、トリプルクリックの解釈） | `ghostty_selection_gesture_*` | Phase 2 の選択。Swift 側で範囲を管理する必要が無くなる |
| 危険なペーストの判定 | `ghostty_paste_is_safe` | Phase 2 の確認シート |
| render hold の callback | `GHOSTTY_TERMINAL_OPT_RENDER_HOLD` | Phase 5 の DECSET 2026。タイムアウトは Swift 側で持つ（ライブラリ側の記述は無い。1 秒） |
| 境界で止める書き込み | `ghostty_terminal_vt_write_until` | 大量出力の分割に使えるが、Phase 5 では使わない（ふつうの書き込みでもシーケンスの途中で区切ってよい） |
| スクロールバックの圧縮 | `ghostty_terminal_compress` | Phase 5 のメモリ対策（30 タブ × 10000 行） |
| 増分の検索（`feed` / `tick` の分離） | `ghostty_search_*` | Phase 5。Terminal を読む時間を最小にできる |
| メモリ使用量の取得 | `GHOSTTY_TERMINAL_DATA_MEMORY_USAGE`（`GhosttyTerminalMemoryUsage`。サイズ付き構造体） | Phase 5 の計測（`VTTerminal.memoryUsage`、docs/performance.md） |
| マウスカーソルの形状（OSC 22） | `GHOSTTY_TERMINAL_DATA_MOUSE_SHAPE` | 任意 |
| プロンプト単位のスクロール | `GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT` | 任意（OSC 133 が前提） |
| WebAssembly 版 | `wasm.h` | 使わない |
