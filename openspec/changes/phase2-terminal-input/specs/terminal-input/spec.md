# Spec Delta

## ADDED Requirements

### Requirement: Input method composition

The terminal view SHALL support macOS input methods. While text is being composed, the uncommitted (marked) text SHALL be drawn over the terminal at the cursor position with an underline and SHALL NOT be written to the terminal or sent to the session. Only committed text SHALL be sent as input. The input method's candidate window SHALL be positioned at the terminal cursor. Keys consumed by the input method (including Enter, Escape, arrows, and Backspace during composition) SHALL NOT be sent to the session.

#### Scenario: Japanese input

- **WHEN** the user types `nihongo` with a Japanese input method, converts it, and confirms with Enter
- **THEN** only the committed text `日本語` is sent to the session, and no `\r` is sent for the confirming Enter

#### Scenario: Candidate window position

- **WHEN** the user starts composing at a cursor in the lower half of the terminal
- **THEN** the candidate window appears adjacent to the cursor cell, not at a corner of the window

#### Scenario: Cancel composition

- **WHEN** the user presses Escape during composition
- **THEN** the marked text disappears and nothing is sent to the session

### Requirement: Shift+Enter sends a newline sequence

When `shift_enter_newline` is enabled (the default), pressing Enter with Shift and without Control, Option, or Command, while no text is being composed, SHALL send `ESC CR` (`\x1b\r`) instead of the normal Enter encoding. This SHALL take precedence over keyboard-protocol encoding. When the setting is disabled, Shift+Enter SHALL be encoded normally.

#### Scenario: Claude Code newline

- **WHEN** `shift_enter_newline` is enabled and the user presses Shift+Enter in Claude Code
- **THEN** the session receives `\x1b\r` and Claude Code inserts a newline instead of submitting

#### Scenario: Plain Enter submits

- **WHEN** the user presses Enter without modifiers
- **THEN** the session receives the normal Enter encoding

#### Scenario: Disabled

- **WHEN** `shift_enter_newline` is false and the user presses Shift+Enter
- **THEN** the key is encoded normally and `\x1b\r` is not sent

#### Scenario: During composition

- **WHEN** the user presses Shift+Enter while composing text
- **THEN** `\x1b\r` is not sent

#### Scenario: Other modifiers

- **WHEN** the user presses Control+Shift+Enter or Option+Shift+Enter
- **THEN** `\x1b\r` is not sent and the key is encoded normally

### Requirement: Yen key types a backslash

A key press that produces `¥` without Control, Option, or Command (Shift allowed), while no text is being composed, SHALL send `\` instead. Pasted text and text committed by an input method SHALL NOT be rewritten.

#### Scenario: JIS keyboard

- **WHEN** the user presses the `¥` key on a JIS keyboard in direct input mode
- **THEN** the session receives `\`

#### Scenario: Pasted yen

- **WHEN** the user pastes text containing `¥`
- **THEN** the session receives `¥` unchanged

#### Scenario: Modified yen

- **WHEN** the user presses Option+`¥`
- **THEN** the key is not rewritten by this rule

### Requirement: Keyboard protocol and focus reporting

When a program enables the kitty keyboard protocol, key events SHALL be reported according to the flags the program requested. When a program enables focus reporting (DECSET 1004), the session SHALL receive `ESC [ I` when the terminal view gains keyboard focus and `ESC [ O` when it loses it.

#### Scenario: Kitty keyboard protocol

- **WHEN** `kitten show-key -m kitty` (or another program using the protocol) is running and the user presses Control+Shift+A
- **THEN** the program receives the kitty-protocol encoding and identifies the key and modifiers correctly

#### Scenario: Focus events

- **WHEN** a program has enabled DECSET 1004 and the user switches to another app and back
- **THEN** the session receives `ESC [ O` followed by `ESC [ I`

### Requirement: Option key composes characters

Option-modified keys SHALL produce the character macOS composes for the current keyboard layout, as the web client does, rather than an ESC-prefixed Meta sequence.

#### Scenario: Option character

- **WHEN** the user presses Option+2 on a US keyboard layout
- **THEN** the session receives `™`

### Requirement: Typing returns to the bottom

When the viewport is scrolled back into history and the user types input that is sent to the session, the viewport SHALL return to the bottom.

#### Scenario: Type while scrolled back

- **WHEN** the user has scrolled up 100 lines and presses a letter key
- **THEN** the viewport shows the bottom of the screen and the letter is sent
