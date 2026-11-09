# Design: Phase 4 — 通知・設定画面・画像添付・配色

## Context

- Phase 3 で、次のものはできている。
  - `SessionStore` が発行する完了イベントと待ちイベント
  - `UnreadTracker`
  - Dock バッジ
  - `ChromePalette`
  - REST の `PATCH /api/config`
- Phase 1 で、`DesktopSupport` に通知関連のコードを残してある。
  - `NativeNotificationService`（`.alert` だけを要求する。`userInfo["sid"]` を入れる。音は鳴らさない。identifier は `webtabinal-<UUID>`）
  - `NotificationActivationCoordinator`
  - `foregroundNotificationPresentationOptions`（`[.banner, .list]`）
- 置き換え元の Web 版の挙動（webtabinal `6dca08f`）:
  - **通知の判定**: `notify.ts` と `App.tsx` の L213-275。順序は spec の 1〜7 のとおり。
  - **コマンドでの絞り込み**: クライアント側で行う（SPEC §1.3 には「デーモン側で完結」とあるが、実装を読むとクライアント側にあった）。
  - **完了通知**: `state` が `running → idle` になったときにクライアントが出す。`exited` になったときは出さない。
  - **設定画面**:
    - 4 カテゴリ。ボタンで保存するのではなく、変更のたびに PATCH を送る。
    - 失敗したら元に戻してトーストを出す。
    - テキストは blur か Enter で確定する。
    - 通知カテゴリでは、保存中に操作できないようにロックする。
  - **設定の変更**: デーモンからの通知は無い（WS のフレームが無い）。Web 版が知っているのは、自分の設定画面で行った変更だけである。
  - **画像**:
    - 受け付ける形式は png / jpeg / gif / webp で、生のバイト列を POST する。10 MiB を超えると 413 になる。
    - エスケープする文字は正規表現 `/[ \t\n"'\\$`&|;<>()*?[\]{}!#]/`。
    - 結果はスペースで区切り、末尾にもスペースを付けて、`term.paste` で入力する。
    - アップロードは 1 つずつ順に行う。失敗したものは飛ばす。
    - アップロード中にタブが切り替わったら貼らない。
  - **配色**:
    - `resolveTheme` は、`light` / `dark` ならその値を使い、それ以外なら `prefers-color-scheme` に従う。
    - ターミナルの配色と chrome のトークンは Phase 1 と Phase 3 で移植済み。
    - デーモンは、`color_scheme` を**新しく作るセッション**の OSC パレットと環境変数（`TERM_THEME` など）にだけ使う。

## Goals / Non-Goals

**Goals:**

- SPEC §7 Phase 4 の完了条件を満たす。
  - OSC 9 のプローブで通知が出る。
  - `webtabinal notify` で通知が出て、クリックするとそのタブに移る。
  - README の通知トラブルシュート表のとおりに動く。
  - 画像を添付できる。
  - 設定が保存され、ブラウザ版にも反映される。
- この Phase が終わった時点で、WebTabinal.app の代わりに日常的に使える状態にする。

**Non-Goals:**

- `notification.sound`。Web 版も使っていないので、扱わない。
- config ファイルにしか無い項目（`min_duration_ms`、`font_*`、`scrollback_lines`、`confirm_close_running`、`copy_on_select`、`quit_when_no_tabs`、`close_tab_on_clean_exit`、`restore.commands`、`port`、`ring_buffer_bytes`）を、設定画面に出すこと。Web 版と同じく、UI には出さない。ただし読み直したときには反映する。
- ブラウザ版と Tabghostty の両方を開いているときに通知が二重に出る問題。これは現行のブラウザ版と `.app` の組み合わせでも同じ。Risks を参照。

## Decisions

### D1. 通知の判定は純粋関数にし、Web 版のテストをそのまま移す

- 判定は `NotificationDecision.evaluate(event:, session:, isActive:, windowFocused:, config:) -> (markUnread: Bool, show: NotificationContent?)` にまとめる。
- webtabinal の `notify.test.ts`（16 件）を Swift Testing に移す。抑止、`min_duration`、`always`、無効のとき、内容のフォールバック、コマンド一覧（basename、引数、空の一覧、未知のコマンド、前後の空白、大文字小文字）、ミュートを含む。
- Phase 3 の `shouldMarkUnread` は、この関数の `markUnread` に置き換える。未読の判定を 1 か所にまとめるため。
- `NotificationCoordinator`（@MainActor）が、`SessionStore` のイベントを受け取る → 判定する → `UnreadTracker` を更新する → `NativeNotificationService.show` を呼ぶ、という流れを受け持つ。

### D2. 通知の配信とクリック

- `UNUserNotificationCenter.current().delegate` は `AppDelegate` にする。
  - `willPresent` では `[.banner, .list]` を返す。
  - `didReceive` では `userInfo["sid"]` を取り出して `NotificationActivationCoordinator` に渡す。
- `SessionStore` が最初の `sessions` を受け取るまでは、渡された sid を保留しておく。受け取ったら、その sid がまだあれば選択する。無ければ何もしない（Web 版の `App.tsx` L203-211 と同じ）。
- 通知の identifier の接頭辞は `tabghostty-` に変える。
- `UNUserNotificationCenter` はバンドルの外では使えない（`swift run` だと落ちる）。そのため、`Bundle.main.bundleIdentifier` が無いときは配信を無効にし、ログを 1 回だけ出す。

### D3. 設定画面

- `NSWindowController` と `NSTabViewController`（toolbar 形式）で作り、4 つのペインを置く。macOS の「設定」ウィンドウとして一般的な見た目にするため。
  - 開くときは常に「外観」を選ぶ（Web 版と同じ）。
- ペインごとに AppKit のコントロールで組み立てる。保存は `ConfigEditor` を経由させる。
  - `ConfigEditor` は、楽観的に更新し、PATCH を送り、失敗したら元に戻してエラーを出す。この処理を 1 か所にまとめる。
  - PATCH のボディは、変更したキーだけを入れた入れ子の JSON にする。デーモンは入れ子のオブジェクトをフィールド単位でマージし、配列は丸ごと置き換える。そのため `commands` は配列全体を送る。
- キーの記録（`KeyRecorder`）では、ボタンが押されたら `NSEvent.addLocalMonitorForEvents(.keyDown)` で次のキーを 1 つ受け取る。
  - Phase 3 の `Keymap.normalize` で表記に直し、`validate` で検証する。
  - Escape で取り消し、修飾キーだけの入力は無視する。
- 通知の許可の状態は、`UNUserNotificationCenter.getNotificationSettings` の値を、Web 版の 4 状態（default / granted / denied / unsupported）に対応させて表示する。

### D4. 設定の配布（`ConfigStore`）

- 設定を持つのは `ConfigStore`（@MainActor、`ObservableObject` 相当）で、各コンポーネントはここを参照する。
  - Phase 1〜3 では起動時に読み込んだ値を直接持っていたが、ここに集約する。
- 次のときに `GET /api/config` で読み直し、変わったキーだけを通知する。
  - `NSApplication.didBecomeActiveNotification`
  - 設定画面を開いたとき
  - WS が再接続したとき
- 値が変わったときの反映先:

| キー | 反映先 |
|---|---|
| `color_scheme` | `AppearanceController` |
| `font_*` | 全 `TerminalView`。セル寸法を計算し直し、resize する |
| `sidebar_width` | サイドバー |
| `scrollback_lines` | これから作る Terminal |
| その他 | 参照のたびに `ConfigStore` を読むので、そのまま反映される |

- `scrollback_lines` を作成済みの Terminal に適用するかどうかは、C API で変更できるかによる（Phase 0 の対応表を見る）。変更できない場合は、新しく作る Terminal にだけ適用する（spec のとおり）。

### D5. 画像の添付

- `ImageAttachService` の処理: 画像のデータを順に受け取り、PNG に変換する（必要な場合）→ アップロードする → 結果を集める → 開始したときの sid と今の active sid を比べる → `TerminalController.paste(text)` を呼ぶ。
- エスケープ、結合、形式の判定は純粋関数にする。webtabinal の `image-attach.test.ts`（11 件）のうち、`clipboard.read` や Blob といったブラウザ API に依存するケースを除いて移す。
- Cmd+V の処理（Phase 2 の `paste` の入口）では、最初に `NSPasteboard` から `.png` を探し、無ければ `.tiff` を探す。TIFF は `NSBitmapImageRep` で PNG に変換する。どちらも無いときだけ、テキストのペーストに進む。
- ドロップは `TerminalView` の `registerForDraggedTypes([.fileURL])` で受ける。
  - `draggingEntered` で、ファイルを含むかどうかを判定し、枠を出す。
  - `performDragOperation` で、各ファイルの形式を `UTType` で判定し、対象の形式なら読み込んで `ImageAttachService` に渡す。
  - 枠は、Web 版と同じ「2px の点線、accent 色、角丸 6、accent の 12% で塗る」をオーバーレイの `CALayer` で描く。

### D6. 配色の動的な切り替え

- `AppearanceController` の動作:
  - `color_scheme` が `system` のときは、`NSApp` の `effectiveAppearance` を KVO で監視する。
  - 解決した配色を、`TerminalView`（パレットを差し替えて全行を再描画）、`ChromePalette`、ウィンドウの `appearance` に配る。
- 設定画面で変えたときは、楽観的に切り替え、PATCH が失敗したら元に戻す。Web 版にある競合への対策（`App.tsx` L485-511。素早く 2 回変えたときに、古い応答で巻き戻らないようにする）も移植する。

## Risks / Trade-offs

- **[Risk] ブラウザ版と Tabghostty の両方で通知の許可があると、同じイベントで 2 回通知が出る。** → 現行のブラウザ版と `.app` を併用した場合と同じ。README（Phase 7）に「ブラウザ版の通知は無効にすることを推奨」と書く。
- **[Risk] 配色が system のとき、デーモンが OSC 10/11/12 に返す値は、セッションを作った時点の外観で決まる。** そのため、外観を切り替えた後は、既存のセッションでデーモンの応答と表示の色がずれる。→ 現行の Web 版と同じ。デーモン側の問題なので、ここでは扱わない。
- **[Risk] `.app` として起動しないと通知を出せない。** → 開発時は `make app` でバンドルを作って確認する。README に書く。
- **[Trade-off] 設定の読み直しは、アプリが前面に来たときなどの都度行う。** プッシュではないので、Tabghostty が裏にいる間にブラウザ版で変えた設定は、前面に来るまで反映されない。ただし、通知の判定は裏にいる間にも行われる。→ 許容する。完全に追従させるにはデーモン側の変更が要るので、別のタスクとする。
