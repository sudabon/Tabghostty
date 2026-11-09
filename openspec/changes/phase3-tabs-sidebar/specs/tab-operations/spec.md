# Spec Delta

## ADDED Requirements

### Requirement: Select a tab

Clicking a tab SHALL make it the active session, show its terminal immediately without replaying history, clear its unread mark, and give its terminal keyboard focus.

#### Scenario: Switch tabs

- **WHEN** the user clicks a background tab that has received output since it was last shown
- **THEN** its terminal is shown with the latest output at once and has keyboard focus

### Requirement: Create, duplicate, and restart tabs

"＋ 新規タブ" and Command-N SHALL create a session with `POST /api/sessions` (home directory) and make it active with keyboard focus. The context menu's duplicate item SHALL call `POST /api/sessions/{id}/duplicate` and its restart item SHALL call `POST /api/sessions/{id}/restart`; in both cases the returned session SHALL become active. Restart SHALL be available only for exited sessions. The tab list itself SHALL change only when the daemon broadcasts `sessions`.

#### Scenario: New tab

- **WHEN** the user presses Command-N
- **THEN** a new session starts in the home directory, appears in the sidebar after the daemon's broadcast, and becomes active

#### Scenario: Restart unavailable

- **WHEN** the user opens the context menu on a running session
- **THEN** the restart item is disabled

### Requirement: Close a tab

The context menu's close item SHALL close the session with `DELETE /api/sessions/{id}`. When `confirm_close_running` is true (the default) and the session's state is `running`, the client SHALL first ask "このタブは実行中です。閉じますか？" and close only if the user confirms. When the active tab is closed, the active session SHALL be chosen by the active-session selection rule.

#### Scenario: Confirm running

- **WHEN** the user closes a tab running `npm run dev`
- **THEN** a confirmation sheet appears and the session is deleted only after the user confirms

#### Scenario: Idle tab

- **WHEN** the user closes an idle tab
- **THEN** it is deleted without confirmation

### Requirement: Reorder tabs by dragging

The user SHALL be able to drag a tab to a new position (a drag starts after the pointer moves 6 points). On drop the client SHALL send `PUT /api/sessions/order` with the complete list of session ids in the new order. The client SHALL NOT sort tabs automatically.

#### Scenario: Reorder visible in browser

- **WHEN** the user drags the third tab to the top
- **THEN** the order is saved and the browser client shows the same order after the daemon's broadcast

### Requirement: Edit a tab memo

Double-clicking a tab SHALL make it active and open a memo editor sheet titled "タブメモ" containing the current memo, a remaining-character counter ("残り N"), and the placeholder "用途を短くメモ（任意）". Input SHALL be limited to 30 Unicode code points. Enter (when not composing with an input method) or the save button SHALL save the trimmed value with `PATCH /api/sessions/{id}` (`memo`); an empty value SHALL clear the memo. Escape or cancel SHALL close the sheet without saving. If saving fails, the sheet SHALL stay open and show the error.

#### Scenario: Save memo

- **WHEN** the user double-clicks a tab, types `  レビュー対応  `, and presses Enter
- **THEN** the memo `レビュー対応` is saved and the browser client shows it after the broadcast

#### Scenario: Limit

- **WHEN** the user tries to type a 31st code point
- **THEN** the field does not accept it

#### Scenario: Enter during conversion

- **WHEN** the user presses Enter to confirm an input-method conversion in the memo field
- **THEN** the conversion is committed and the memo is not saved yet

### Requirement: Tab context menu

Right-clicking a tab SHALL open a context menu with these items:

- 複製
- 再起動 (enabled only when exited)
- 閉じる
- 通知 (a checkmark item, checked when the tab is not muted)

Only one context menu SHALL be open at a time, and opening it SHALL NOT start a drag.

#### Scenario: Menu items

- **WHEN** the user right-clicks an exited tab that is not muted
- **THEN** the menu shows 複製, an enabled 再起動, 閉じる, and a checked 通知

### Requirement: Per-tab notification mute

Choosing 通知 in the context menu SHALL toggle the session's `notifications_muted` with `PATCH /api/sessions/{id}`, updating the menu state immediately and reverting it with an error message if the request fails.

#### Scenario: Mute

- **WHEN** the user unchecks 通知 for a tab
- **THEN** the tab is muted, and the browser client shows it muted after the broadcast

#### Scenario: Failure

- **WHEN** the PATCH request fails
- **THEN** the checkmark returns to its previous state and an error message is shown

### Requirement: Behavior when the last tab closes

When the number of sessions changes from one or more to zero and `quit_when_no_tabs` is true (the default), the app SHALL close its window and quit, leaving the daemon running. When `quit_when_no_tabs` is false, the window SHALL show "すべてのタブを閉じました" with a "＋ 新規タブ" action.

#### Scenario: Quit on last close

- **WHEN** the user closes the only tab and `quit_when_no_tabs` is true
- **THEN** the app quits and the daemon keeps running

#### Scenario: Empty state

- **WHEN** the last tab closes and `quit_when_no_tabs` is false
- **THEN** the empty state is shown and "＋ 新規タブ" creates a session
