# Spec Delta

## Purpose

Defines the native settings window that edits the daemon's shared configuration, and how configuration changes made by any client are reflected in Tabghostty.

## ADDED Requirements

### Requirement: Settings window layout

Choosing 設定 in the sidebar or pressing Command-, SHALL open a single settings window with the categories 外観, 一般, 通知, and キーボード, in that order, opening on 外観. There SHALL be no save button: each change SHALL be saved immediately with `PATCH /api/config`. If a save fails, the control SHALL return to its previous value and the error SHALL be shown in the window.

#### Scenario: Immediate save

- **WHEN** the user turns off 通知を有効にする
- **THEN** `PATCH /api/config` is sent with `notification.enabled: false` without any further action

#### Scenario: Save failure

- **WHEN** the daemon rejects a change
- **THEN** the control shows the previous value and an error message is displayed

### Requirement: Appearance category

The 外観 category SHALL offer テーマ with the choices ライト, ダーク, and 自動, saved as `color_scheme` `light`, `dark`, and `system`.

#### Scenario: Choose dark

- **WHEN** the user selects ダーク
- **THEN** `color_scheme: "dark"` is saved and the app switches to the dark scheme immediately

### Requirement: General category

The 一般 category SHALL offer:

- 起動シェル, a text field for `shell` that commits on focus loss or Enter (not during input-method composition), trims the value, reverts without saving when empty or unchanged, reverts when the daemon rejects the path, and explains that the change applies to new tabs.
- セッションの復元, a checkbox for `restore.enabled`.

#### Scenario: Invalid shell

- **WHEN** the user enters `/no/such/shell` and presses Enter
- **THEN** the daemon rejects it, the field returns to the previous shell, and an error is shown

### Requirement: Notifications category

The 通知 category SHALL offer:

- 通知を有効にする (`notification.enabled`).
- 操作中も通知する (`notification.always`).
- 通知するコマンド, an editable list of `notification.commands`. Adding trims the name and ignores a case-insensitive duplicate. Removing deletes the entry. An empty list is described as 「すべてのセッションが通知します」.
- 状態検出を有効にする (`state.enabled`).
- blocked を通知する (`state.notify_on_blocked`).
- 画面検知でプロンプト復帰を通知する (`state.notify_on_idle`). This and the previous item are disabled while state detection is off.
- A collapsible 詳細設定 section with numeric fields `state.debounce_ms` (20–5000), `state.quiescence_ms` (0–60000), and `state.bottom_lines` (1–200), and a text field `state.manifest_dir`, each committed on focus loss, reverting when not a number or unchanged.
- The notification permission state and the authorization button defined by the notifications capability.

Controls SHALL be disabled while a save from this category is in progress.

#### Scenario: Add command

- **WHEN** the user adds ` Codex ` while `codex` is already listed
- **THEN** the list is unchanged and nothing is saved

#### Scenario: Detection off

- **WHEN** the user turns off 状態検出を有効にする
- **THEN** the two state notification checkboxes become disabled

### Requirement: Keyboard category

The キーボード category SHALL offer:

- Shift+Enter で改行する (`shift_enter_newline`).
- ショートカットを有効にする (`key_bindings.enabled`).
- Recorder buttons for プレフィックス, 次のタブ, 前のタブ, and サイドバー開閉. Clicking one shows 「キーを入力…」 and records the next non-modifier key press in key binding notation. Escape cancels recording.
- キー割り当てをリセット, which restores the default bindings while keeping `enabled`.

A recorded binding that fails validation SHALL be rejected with a message and the previous binding kept.

#### Scenario: Record prefix

- **WHEN** the user clicks プレフィックス and presses Control+K
- **THEN** `key_bindings.prefix: "ctrl+k"` is saved and the chord uses Control-K immediately

#### Scenario: Reserved

- **WHEN** the user records Command-N as the prefix
- **THEN** the binding is rejected as reserved and the previous prefix remains

### Requirement: Configuration changes take effect without restart

Tabghostty SHALL re-read the configuration with `GET /api/config` when the app becomes active, when the settings window opens, and after the WebSocket reconnects. Changed values SHALL take effect immediately:

- `color_scheme`, `shift_enter_newline`, `copy_on_select`, `key_bindings`, `notification.*`, `confirm_close_running`, and `quit_when_no_tabs` for all behavior.
- `font_family` and `font_size` for all terminals, with a grid resize.
- `sidebar_width` for the sidebar.
- `scrollback_lines` for terminals created afterwards.

#### Scenario: Changed in browser

- **WHEN** the user turns off notifications in the browser client and then switches to Tabghostty
- **THEN** Tabghostty stops showing notifications without restarting

#### Scenario: Font change

- **WHEN** `font_size` changes to 16 in the configuration and Tabghostty becomes active
- **THEN** all terminals redraw at 16 points and send `resize` with the new grid size
