# keyboard-shortcuts Specification

## Purpose
Defines the app-level keyboard shortcuts for tab creation and navigation, including the configurable prefix chord, and guarantees they never leak keystrokes to the terminal.

## Requirements

### Requirement: Command shortcuts

Command-N SHALL create a new tab. Command-1 through Command-9 SHALL select the tab at that position when it exists and do nothing otherwise. These shortcuts SHALL be menu key equivalents and SHALL NOT send bytes to the session.

#### Scenario: Select second tab

- **WHEN** three tabs exist and the user presses Command-2
- **THEN** the second tab becomes active and nothing is sent to any session

#### Scenario: Missing position

- **WHEN** two tabs exist and the user presses Command-5
- **THEN** nothing happens and nothing is sent to any session

### Requirement: Key binding notation and validation

Key bindings SHALL use the `key_bindings` setting (`enabled`, `prefix`, `next_tab`, `prev_tab`, `toggle_sidebar`; defaults `false`, `ctrl+j`, `n`, `p`, `j`). A binding is a lowercase string of modifiers in the order `ctrl`, `alt`, `shift`, `meta` followed by one key, joined with `+` (`space` and `escape` name those keys). A key event SHALL be normalized to this notation using the produced key in lowercase; modifier-only presses and keys pressed during input-method composition SHALL normalize to nothing. A configuration SHALL be rejected when a binding is unparsable, uses `escape`, the prefix has no modifier, two actions share a key, or the prefix is `meta+1`…`meta+9`, `meta+n`, `meta+c`, or `meta+v`.

#### Scenario: Normalization order

- **WHEN** the user presses Control+Shift+K
- **THEN** the event normalizes to `ctrl+shift+k`

#### Scenario: Reserved prefix

- **WHEN** the configuration's prefix is `meta+n`
- **THEN** the configuration is rejected as reserved

### Requirement: Prefix chord for tab navigation

When `key_bindings.enabled` is true, pressing the prefix SHALL arm a pending chord for 3 seconds. While pending:

- the next-tab key SHALL select the next tab and the previous-tab key SHALL select the previous tab, both wrapping around (with one tab they do nothing);
- the toggle-sidebar key SHALL toggle the sidebar;
- pressing the prefix again SHALL restart the 3-second timer;
- Escape or any other key SHALL cancel the chord.

The prefix and every key handled or cancelled by the chord SHALL be consumed and SHALL NOT reach the terminal. The chord SHALL be evaluated before terminal key handling. When `enabled` is false, all keys SHALL pass through to the terminal unchanged.

#### Scenario: Next tab

- **WHEN** chords are enabled and the user presses Control-J then N on the last tab
- **THEN** the first tab becomes active and neither key reaches the terminal

#### Scenario: Cancel

- **WHEN** the user presses Control-J then X
- **THEN** the chord is cancelled, the active tab does not change, and X is not sent to the terminal

#### Scenario: Disabled passthrough

- **WHEN** chords are disabled and the user presses Control-J
- **THEN** the terminal receives `0x0a`

### Requirement: Pending chord is visible and cancellable

While a chord is pending, the window SHALL show an indicator at the bottom center with the prefix in display form (for example `Ctrl+J …`, with `meta` shown as `Cmd`). The pending chord SHALL be cancelled when it times out after 3 seconds, when the window loses focus, or when the settings window or memo editor opens. Chords SHALL NOT be recognized while the settings window or memo editor is open or while a text field has focus.

#### Scenario: Timeout

- **WHEN** the user presses Control-J and waits 3 seconds
- **THEN** the indicator disappears and the next key goes to the terminal

#### Scenario: Memo editor open

- **WHEN** the memo editor is open and the user presses Control-J
- **THEN** no chord is armed
