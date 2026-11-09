# Proposal: Phase 3 — タブ・サイドバー・状態表示・ショートカット

## Why

Phase 2 までの Tabghostty は、1 つのセッションしか表示できない。WebTabinal の中心はサイドバーでの複数タブ管理で、具体的には次のような機能がある。

- エージェントの状態 pill
- 未読ドットと Dock バッジ
- 右クリックメニュー
- タブメモ
- Cmd+N、Cmd+1〜9、Ctrl+J のコード

SPEC.md §7 Phase 3 は、これらを Web 版と同じ挙動で実装し、ブラウザ版との間で設定が相互に即時反映されることを求めている。

## What Changes

- **サイドバー**
  - 左側に置く。幅は `sidebar_width`（既定 240、ドラッグで 160〜480、離した時点で `PATCH /api/config`）。折りたたむことができる（状態は保存しない）。
  - 各行は 3 段で、内容は次のとおり。
    1. cwd の basename、`◌`（シェル統合が無効）、未読ドット、状態 pill
    2. コマンド
    3. 状態（`● running m:ss` / `■ exit N` / `○ starting` / `○ idle`）
  - メモは、1 秒ホバーするとツールチップで出す。
- **状態 pill**
  - `agent_state` が `idle` / `working` / `blocked` のときに表示する。`none` のときは出さない。
  - working のスピナーは、「視差効果を減らす」設定に従う。
- **未読ドットと Dock バッジ**
  - 条件は Web 版と同じにする（`App.tsx` の `shouldRaiseDesktopNotification` が通り、かつ非アクティブのタブ）。
  - バッジの数は未読タブの数。
  - 閉じたタブは未読から取り除く（Web 版で数が残ってしまう不具合を直す）。
- **タブ操作**
  - 新規、複製、再起動（終了済みのタブだけ）、閉じる（実行中なら確認する）。
  - ドラッグで並べ替える（`PUT /api/sessions/order`。自動ソートはしない）。
  - メモの編集シート（30 文字まで）。
  - 右クリックメニュー（複製 / 再起動 / 閉じる / 通知のチェック）。
  - 通知ミュートの切り替え（楽観的に更新し、失敗したら戻す）。
  - `quit_when_no_tabs` に従い、タブが 0 になったら終了する。そうしない設定のときは「すべてのタブを閉じました」を表示する。
- **全タブ attach**
  - すべてのセッションを attach したままにする。裏のタブも Terminal を更新し続ける（SPEC §4.3）。
  - タブを切り替えても、replay はしない。
- **ショートカット**
  - Cmd+N と Cmd+1〜9 をメニューのキー等価物にする。
  - Ctrl+J のコード（`key_bindings`。既定は無効、タイムアウト 3 秒、保留中は表示を出す）。ターミナルへのキー送信より前に判定する。
  - 「サイドバーを表示/隠す」メニュー項目（キー等価物なし）。
- **フォーカス**
  - タブの選択、新規作成、サイドバーの開閉の後に、ターミナルにフォーカスを戻す。

## Capabilities

### New Capabilities

- `tab-sidebar`
  - サイドバーのレイアウト、行の表示、状態 pill、未読ドット、Dock バッジ。
  - メモのツールチップ、折りたたみ、幅の変更。
- `keyboard-shortcuts`
  - Cmd+N、Cmd+1〜9、プレフィックスによるコード、表記と検証、保留状態の表示、無効にする条件。

### Modified Capabilities

Phase 2 の change を先に archive しておくこと。

- `tab-operations`
  - 新規、複製、再起動、閉じる（確認あり）、並べ替え、メモの編集、通知ミュート、右クリックメニュー、タブが 0 になったときの挙動を追加する。
- `terminal-session`
  - 全セッションを同時に attach し続けること、タブを切り替えても replay しないこと、セッションが一覧に増えたときと消えたときの扱いを追加する。

## Impact

- 新規モジュール `Shell` に、次を置く。
  - SidebarView（`NSTableView`）
  - TabRowView
  - AgentStatePillView
  - TabContextMenu
  - MemoSheet
  - Keymap
  - UnreadTracker
  - DockBadge
- `TerminalUI` は、セッションごとに `TerminalView` を持ち、切り替えて表示する形に変える。
- `DaemonClient` の REST に、次を追加する。
  - duplicate
  - DELETE
  - PATCH session
  - PUT order
  - PATCH config（`sidebar_width`）
- テストを移植する: webtabinal `web/tests` の `keymap.test.ts`、`session-state.test.ts`、`tab-menu.test.ts`、`util.test.ts` の該当分、`agent-state-pill.test.ts`。
- メモリの使用量が増える（全タブ × スクロールバック）。計測は Phase 5 の完了条件で行う。
- webtabinal（デーモン・web）は変更しない。
