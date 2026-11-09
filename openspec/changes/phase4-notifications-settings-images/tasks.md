# Tasks

> 前提: `phase3-tabs-sidebar` が完了し、archive 済みであること。通知の動作は `make app` で作った `.app` で確認すること。

## 1. 設定の集約と読み直し（spec: settings-window）

- [ ] 1.1 `ConfigStore`（@MainActor）を作り、Phase 1〜3 で各コンポーネントが直接持っていた設定値をここに集約する。次のときに `GET /api/config` で読み直し、変わったキーだけを通知する
  - アプリが前面に来たとき
  - 設定画面を開いたとき
  - 再接続したとき

  変わったキーの検出と、そのキーにだけ通知が届くことをテストで確認する
- [ ] 1.2 `ConfigEditor` を作る。楽観的に更新し、変更したキーだけを入れた入れ子の PATCH を送り、失敗したら元に戻してエラーを出す。PATCH のボディの形（`commands` は配列全体を送る）と、失敗時に元に戻ることをモック HTTP でテストで確認する
- [ ] 1.3 `font_family` / `font_size` の変更を全 Terminal に反映する（セル寸法の再計算と resize）。`sidebar_width` と `scrollback_lines`（作成済みの Terminal に適用できるかは対応表を見て決める）も反映する。config の font_size を変えてからアプリを前面に戻すと、表示が変わることを確認する（要手動確認）

## 2. 配色（spec: color-scheme）

- [ ] 2.1 `AppearanceController` を作る。`system` のときは effectiveAppearance を KVO で監視し、解決した配色をパレット、chrome、ウィンドウの appearance に配る。webtabinal `theme.test.ts`（3 件）を移植して通ることを確認する。macOS の外観を切り替えると即座に追従することを確認する（要手動確認）
- [ ] 2.2 設定画面からの楽観的な切り替え、失敗したときの巻き戻し、競合への対策（`App.tsx` L485-511 相当）を実装する。webtabinal `app.test.ts` の「color-scheme race」のケースを移植して通ることを確認する

## 3. 通知（spec: notifications）

- [ ] 3.1 `NotificationDecision.evaluate` を作り、Phase 3 の `shouldMarkUnread` を置き換える。webtabinal `notify.test.ts`（16 件）を移植して通ることを確認する
- [ ] 3.2 `NotificationCoordinator` を作る（イベント → 判定 → `UnreadTracker` → `NativeNotificationService`）。通知の内容（`✓` / `✗ (exit N)`、`dir ・ Ns`、title のフォールバック）を作る処理をテストで確認する
- [ ] 3.3 `UNUserNotificationCenter` の delegate を設定し、前面にあるときの表示（`[.banner, .list]`）とクリックしたときの選択（`sessions` を受け取るまで保留し、無くなったタブなら何もしない）を実装する。identifier の接頭辞を `tabghostty-` にし、バンドルの外では配信を無効にする。保留と選択の処理を `NotificationActivationCoordinator` のテストで確認する
- [ ] 3.4 `scripts/osc9-notification-probe.sh`（webtabinal にあるもの）を Tabghostty の裏のタブで実行し、通知が出ることを確認する（要手動確認）
- [ ] 3.5 `webtabinal notify --title "Claude Code" --body "Turn complete"` を裏のタブで実行し、通知が出ること、クリックするとそのタブに移ることを確認する（要手動確認）

## 4. 設定画面（spec: settings-window, notifications）

- [ ] 4.1 `SettingsWindowController`（4 ペイン、常に「外観」で開く、Cmd+, とサイドバーの「設定」から開く）と「外観」ペインを作る。テーマを選ぶと即座に保存・反映されることを確認する（要手動確認）
- [ ] 4.2 「一般」ペインを作る（起動シェルは blur か Enter で確定し、変換中は確定しない。前後の空白を削り、空か変わっていなければ元に戻す。デーモンに拒否されたら元に戻す。説明文を付ける。セッションの復元のチェックボックス）。確定の判定をテストで確認する。存在しないパスを入れるとエラーになって元に戻ることを確認する（要手動確認）
- [ ] 4.3 「通知」ペインを作る。項目は次のとおり
  - 有効にする / 操作中も通知する
  - コマンドのチップ（追加するときに前後の空白を削り、大文字小文字を区別せずに重複を無視する。空のときは説明を出す）
  - 状態検出の 3 項目（検出が無効のときは後ろの 2 つを無効にする）
  - 詳細設定（数値は blur で確定し、数値でないか変わっていなければ元に戻す）
  - 保存中のロック
  - 許可の状態とボタン（notDetermined のときだけボタンを出す。開いたときと前面に来たときに更新する）

  webtabinal `settings-modal.test.ts` のうち通知に関するケースを移植して通ることを確認する
- [ ] 4.4 「キーボード」ペインを作る（Shift+Enter、ショートカットの有効化、4 つの記録ボタン、リセット）。`KeyRecorder` の動作（Escape で取り消す、修飾キーだけは無視する、検証に失敗したら元に戻してメッセージを出す）をテストで確認する。記録したプレフィックスがすぐにコードで使えることを確認する（要手動確認）
- [ ] 4.5 設定画面で変えた全項目が `PATCH /api/config` で保存され、ブラウザ版の設定画面を開き直すと反映されていることを確認する（要手動確認）

## 5. 画像の添付（spec: image-attach, terminal-clipboard）

- [ ] 5.1 エスケープ、結合（末尾のスペースを含む）、形式の判定を純粋関数として作る。webtabinal `image-attach.test.ts` のうちブラウザ API に依存しない部分を移植して通ることを確認する
- [ ] 5.2 `RESTClient` に画像のアップロード（生のバイト列、`{path,name,mime,bytes}`、413 / 415 は失敗として扱う）を追加し、`ImageAttachService` を作る（1 つずつ順に送る、失敗は飛ばす、sid が変わったら貼らない、live のときだけ貼る）。モックを使って「1 件失敗」「途中でタブを切り替えた」ケースをテストで確認する
- [ ] 5.3 Cmd+V で画像を優先する処理を実装する（PNG、TIFF → PNG の変換。画像が無ければテキストのペーストへ）。pasteboard の内容ごとの分岐をテストで確認する
- [ ] 5.4 ドロップ（`registerForDraggedTypes`、ドロップ枠、形式の判定）を実装する。画像をペーストしたときとドロップしたときに、Claude Code にパスが入力されることを確認する（要手動確認）

## 6. 完了条件の確認（SPEC §7 Phase 4）

- [ ] 6.1 README（webtabinal）の通知トラブルシュート表の各状況を再現し、現行と同じ結果になることを確認する（要手動確認）。特に次の 3 点を確認する
  - フォーカス中は通知が抑止されること
  - ミュート中は通知は出ないが、未読とバッジは付くこと
  - `notification.commands` での絞り込み
- [ ] 6.2 Tabghostty.app を 1 週間ほど日常的に使い、見つかった不具合を記録して対応する（要手動確認。SPEC §7 Phase 4 の注記）
