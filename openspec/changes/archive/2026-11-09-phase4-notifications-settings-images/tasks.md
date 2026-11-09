# Tasks

> 前提: `phase3-tabs-sidebar` が完了し、archive 済みであること。通知の動作は `make app` で作った `.app` で確認すること。

## 1. 設定の集約と読み直し（spec: settings-window）

- [x] 1.1 `ConfigStore`（@MainActor）を作り、Phase 1〜3 で各コンポーネントが直接持っていた設定値をここに集約する。次のときに `GET /api/config` で読み直し、変わったキーだけを通知する
  - アプリが前面に来たとき
  - 設定画面を開いたとき
  - 再接続したとき

  変わったキーの検出と、そのキーにだけ通知が届くことをテストで確認する
  - 実装済み（2026-11-09）: `ConfigStore`（DaemonClient）は表示用の `settings` と保存済みの `committed` を持ち、`ConfigKey` 単位で変わったキーだけを知らせる。読み直しは `AppDelegate` から、アプリが前面に来たとき・設定画面を開いたとき・再接続したとき（最初の接続を除く）に行う。保存中のキーと、読み直しの最中に保存が終わったキーは、読み直しの結果で上書きしない。`TabShellController` の `settings` は参照のたびに `ConfigStore` から読む
- [x] 1.2 `ConfigEditor` を作る。楽観的に更新し、変更したキーだけを入れた入れ子の PATCH を送り、失敗したら元に戻してエラーを出す。PATCH のボディの形（`commands` は配列全体を送る）と、失敗時に元に戻ることをモック HTTP でテストで確認する
- [x] 1.3 `font_family` / `font_size` の変更を全 Terminal に反映する（セル寸法の再計算と resize）。`sidebar_width` と `scrollback_lines`（作成済みの Terminal に適用できるかは対応表を見て決める）も反映する。config の font_size を変えてからアプリを前面に戻すと、表示が変わることを確認する（要手動確認）
  - 実装済み（2026-11-09）: フォントを変えると全セッションに新しいグリッドで `resize` を送ること、`sidebar_width`、`shift_enter_newline` / `copy_on_select`、`key_bindings`、`confirm_close_running` / `quit_when_no_tabs` の反映はテストで確認済み。`scrollback_lines` は、対応表のとおり libghostty がいつでも上限を変えられる（`SCROLLBACK_MAX_LINES`）ので、作成済みの Terminal にも反映する（`TerminalController.setMaxScrollback`）。サイドバーの幅をドラッグで変えたときも `ConfigEditor` で保存するので、保存に失敗すると保存済みの幅に戻ってトーストが出る（Phase 3 はトーストだけ）。手動確認も OK（2026-11-09）

## 2. 配色（spec: color-scheme）

- [x] 2.1 `AppearanceController` を作る。`system` のときは effectiveAppearance を KVO で監視し、解決した配色をパレット、chrome、ウィンドウの appearance に配る。webtabinal `theme.test.ts`（3 件）を移植して通ることを確認する。macOS の外観を切り替えると即座に追従することを確認する（要手動確認）
  - 実装済み（2026-11-09）: 配色は端末（`TerminalView.setPalette` と全セッションの `TerminalController.setColors`）、サイドバーなど chrome、メインウィンドウと設定画面の `appearance` に配る。`theme.test.ts` の 3 件は、コントラスト比 4.5 と配色の値、デーモンの OSC パレットとの一致（値を固定して確認。テストの実行に webtabinal は要らない）、作成時と切り替え時に端末の配色が変わること、として移した（`ThemeTests`）。手動確認も OK（2026-11-09）
- [x] 2.2 設定画面からの楽観的な切り替え、失敗したときの巻き戻し、競合への対策（`App.tsx` L485-511 相当）を実装する。webtabinal `app.test.ts` の「color-scheme race」のケースを移植して通ることを確認する
  - 実装済み（2026-11-09）: 競合への対策は配色に限らず `ConfigEditor` がキーごとに行う（古い応答で新しい表示を巻き戻さない。古い失敗はエラーを出さない）。`app.test.ts` の 2 件に加え、「古い変更の成功が、保存中の新しい変更の表示を上書きしない」ケースも確認した（Web 版は一瞬上書きする）

## 3. 通知（spec: notifications）

- [x] 3.1 `NotificationDecision.evaluate` を作り、Phase 3 の `shouldMarkUnread` を置き換える。webtabinal `notify.test.ts`（16 件）を移植して通ることを確認する
  - 実装済み（2026-11-09）: title のフォールバックの最後は `WebTabinal` ではなく `Tabghostty` にした。Phase 3 の `shouldMarkUnread` と `UnreadTracker.handle` は削除し、未読は `NotificationDecision` の `markUnread` だけで決める
- [x] 3.2 `NotificationCoordinator` を作る（イベント → 判定 → `UnreadTracker` → `NativeNotificationService`）。通知の内容（`✓` / `✗ (exit N)`、`dir ・ Ns`、title のフォールバック）を作る処理をテストで確認する
- [x] 3.3 `UNUserNotificationCenter` の delegate を設定し、前面にあるときの表示（`[.banner, .list]`）とクリックしたときの選択（`sessions` を受け取るまで保留し、無くなったタブなら何もしない）を実装する。identifier の接頭辞を `tabghostty-` にし、バンドルの外では配信を無効にする。保留と選択の処理を `NotificationActivationCoordinator` のテストで確認する
  - 実装済み（2026-11-09）: `NativeNotificationService` を async の public API にし、旧 desktop の通知のテストも移した。バンドルの外では `UNUserNotificationCenter` に触れず、許可の状態は unsupported、通知を出そうとしたときに 1 回だけログを出す。起動をやり直したとき（再試行）は、セッション一覧を受け取るまで再び保留する（`markNotReady`）
- [x] 3.4 `scripts/osc9-notification-probe.sh`（webtabinal にあるもの）を Tabghostty の裏のタブで実行し、通知が出ることを確認する（要手動確認）
  - 確認済み（2026-11-09）: 手動確認 OK
- [x] 3.5 `webtabinal notify --title "Claude Code" --body "Turn complete"` を裏のタブで実行し、通知が出ること、クリックするとそのタブに移ることを確認する（要手動確認）
  - 確認済み（2026-11-09）: 手動確認 OK

## 4. 設定画面（spec: settings-window, notifications）

- [x] 4.1 `SettingsWindowController`（4 ペイン、常に「外観」で開く、Cmd+, とサイドバーの「設定」から開く）と「外観」ペインを作る。テーマを選ぶと即座に保存・反映されることを確認する（要手動確認）
  - 実装済み（2026-11-09）: カテゴリの順序、開くたびに「外観」を選ぶこと、テーマを選ぶとすぐに `color_scheme` を保存して切り替わること、失敗したら戻してエラーを出すこと、アプリメニューの「設定…」（Command-,）はテストで確認済み。メインメニューに「閉じる」が無いので、設定画面だけ Command-W で閉じられるようにした。手動確認も OK（2026-11-09）
- [x] 4.2 「一般」ペインを作る（起動シェルは blur か Enter で確定し、変換中は確定しない。前後の空白を削り、空か変わっていなければ元に戻す。デーモンに拒否されたら元に戻す。説明文を付ける。セッションの復元のチェックボックス）。確定の判定をテストで確認する。存在しないパスを入れるとエラーになって元に戻ることを確認する（要手動確認）
  - 実装済み（2026-11-09）: 確定の判定（`SettingsRules.shellCommit`）、デーモンに拒否されたら戻してデーモンの本文をエラーとして出すこと、セッションの復元の保存と巻き戻しはテストで確認済み。変換中の Enter は IME の確定に使われ、欄の確定にはならない（AppKit のフィールドエディタの動作）。手動確認も OK（2026-11-09）
- [x] 4.3 「通知」ペインを作る。項目は次のとおり
  - 有効にする / 操作中も通知する
  - コマンドのチップ（追加するときに前後の空白を削り、大文字小文字を区別せずに重複を無視する。空のときは説明を出す）
  - 状態検出の 3 項目（検出が無効のときは後ろの 2 つを無効にする）
  - 詳細設定（数値は blur で確定し、数値でないか変わっていなければ元に戻す）
  - 保存中のロック
  - 許可の状態とボタン（notDetermined のときだけボタンを出す。開いたときと前面に来たときに更新する）

  webtabinal `settings-modal.test.ts` のうち通知に関するケースを移植して通ることを確認する
  - 実装済み（2026-11-09）: `settings-modal.test.ts` の通知に関する 6 件を移した。許可の状態の文言はネイティブ版に合わせた（ブラウザの話を外し、拒否のときは「システム設定 > 通知」、unsupported のときは `make app` を案内する）。詳細設定の欄は、フォーカスを失ったときに加えて Enter でも確定する
- [x] 4.4 「キーボード」ペインを作る（Shift+Enter、ショートカットの有効化、4 つの記録ボタン、リセット）。`KeyRecorder` の動作（Escape で取り消す、修飾キーだけは無視する、検証に失敗したら元に戻してメッセージを出す）をテストで確認する。記録したプレフィックスがすぐにコードで使えることを確認する（要手動確認）
  - 実装済み（2026-11-09）: `KeyRecorder` の動作、Command-N を予約済みとして拒否すること、記録したプレフィックスが保存されて `ChordController` にすぐ反映されること、リセットで有効かどうかを保つことはテストで確認済み。記録中のキーはローカルモニタで受け取り、メニューのショートカットにも渡さない。設定画面がフォーカスを失ったら記録を取り消す。手動確認も OK（2026-11-09）
- [x] 4.5 設定画面で変えた全項目が `PATCH /api/config` で保存され、ブラウザ版の設定画面を開き直すと反映されていることを確認する（要手動確認）
  - 確認済み（2026-11-09）: 手動確認 OK

## 5. 画像の添付（spec: image-attach, terminal-clipboard）

- [x] 5.1 エスケープ、結合（末尾のスペースを含む）、形式の判定を純粋関数として作る。webtabinal `image-attach.test.ts` のうちブラウザ API に依存しない部分を移植して通ることを確認する
  - 実装済み（2026-11-09）: 11 件のうち、`readClipboardImage`（2 件）と `blobFromBase64` を除く 8 件を移した（`attachableImages` と `dragCarriesFiles` は、ファイルの URL と pasteboard を受け取る形にした）
- [x] 5.2 `RESTClient` に画像のアップロード（生のバイト列、`{path,name,mime,bytes}`、413 / 415 は失敗として扱う）を追加し、`ImageAttachService` を作る（1 つずつ順に送る、失敗は飛ばす、sid が変わったら貼らない、live のときだけ貼る）。モックを使って「1 件失敗」「途中でタブを切り替えた」ケースをテストで確認する
- [x] 5.3 Cmd+V で画像を優先する処理を実装する（PNG、TIFF → PNG の変換。画像が無ければテキストのペーストへ）。pasteboard の内容ごとの分岐をテストで確認する
- [x] 5.4 ドロップ（`registerForDraggedTypes`、ドロップ枠、形式の判定）を実装する。画像をペーストしたときとドロップしたときに、Claude Code にパスが入力されることを確認する（要手動確認）
  - 実装済み（2026-11-09）: 形式はファイルの種類（`UTType`）で決め、拡張子が無いなどただのデータなら中身（先頭のバイト列）で決める。PNG とテキストのファイルを落としたときに PNG だけを添付すること、ファイルを運ばないドラッグ（タブの並べ替え）を受け付けないことはテストで確認済み。手動確認も OK（2026-11-09）

## 6. 完了条件の確認（SPEC §7 Phase 4）

- [x] 6.1 README（webtabinal）の通知トラブルシュート表の各状況を再現し、現行と同じ結果になることを確認する（要手動確認）。特に次の 3 点を確認する
  - フォーカス中は通知が抑止されること
  - ミュート中は通知は出ないが、未読とバッジは付くこと
  - `notification.commands` での絞り込み
  - 確認済み（2026-11-09）: 3 点を含め、手動確認 OK
- [x] 6.2 Tabghostty.app を 1 週間ほど日常的に使い、見つかった不具合を記録して対応する（要手動確認。SPEC §7 Phase 4 の注記）
  - 確認済み（2026-11-09）: 利用者の確認で不具合の報告は無かった。あわせて Phase 4 の差分をレビューし、次の不具合を直した（回帰テストを追加）
    - 起動シェルと詳細設定の欄を編集している間に、読み直しで値が変わることがある。そのあと何も入力せずに確定すると、古い値で上書きしていた。編集されていなければ保存せず、新しい値を出すようにした
    - 起動シェルを保存している間に次の値を確定すると、黙って捨てていた。保存が終わってから保存するようにした
    - サイドバーを折りたたんでいる間や、最初のレイアウトの前に `sidebar_width` が変わると、反映されなかった。展開したとき・最初のレイアウトで使うようにした
    - 通知するコマンドの追加に失敗すると、入力したコマンドが欄から消えていた。保存できたときだけ欄を空にするようにした
    - ドロップしたファイルの拡張子を macOS が知らないとき（動的な種類）に、中身が画像でも添付しなかった。種類が分からないファイルは中身で決めるようにした
    - パスのエスケープを書記素の単位で行っていたので、CR LF やスペースのあとの結合文字で Web 版の正規表現と結果がずれていた。Unicode スカラーの単位にした
