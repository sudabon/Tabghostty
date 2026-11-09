# Spec Delta

## ADDED Requirements

### Requirement: Responsiveness under heavy output

While a session produces sustained heavy output, the app SHALL keep responding to user input: a key typed into any session SHALL be sent, and its echo SHALL appear, within 100 ms. Window interaction (switching tabs, scrolling, resizing) SHALL remain usable.

#### Scenario: 50 MB of text

- **WHEN** `cat` prints a 50 MB text file in one tab and the user types in another tab
- **THEN** each typed character is echoed within 100 ms and the UI does not freeze

#### Scenario: Interrupt heavy output

- **WHEN** the user presses Control-C during the 50 MB `cat`
- **THEN** `0x03` is sent within 100 ms

### Requirement: Idle efficiency

When no session produces output and the user is not interacting, the app SHALL draw nothing except the cursor blink, keeping CPU usage near zero. Frames SHALL be drawn in sync with the display refresh, and no frame SHALL be drawn when nothing changed.

#### Scenario: Idle CPU

- **WHEN** Tabghostty is idle with 10 tabs open for one minute
- **THEN** its average CPU usage is below 1% of one core

#### Scenario: Hidden window

- **WHEN** the window is minimized or fully hidden
- **THEN** no frames are drawn, including cursor blink frames

### Requirement: Synchronized output

When a program enables synchronized output (DECSET 2026), the terminal view SHALL not present intermediate screen states until the program disables it or the terminal engine's safety timeout expires.

#### Scenario: Flicker-free redraw

- **WHEN** a TUI wraps a full-screen redraw in `ESC[?2026h` … `ESC[?2026l`
- **THEN** only the completed screen is displayed, with no partially drawn frame

### Requirement: Rendering parity

Switching between rendering implementations SHALL NOT change what is displayed: colors, attributes, wide characters, fallback glyphs, cursor, selection, and IME marked text SHALL look the same as specified by the existing rendering requirements.

#### Scenario: Visual comparison

- **WHEN** the same session is displayed with each renderer
- **THEN** screenshots of `ls --color`, `vim`, `htop`, and a CJK/emoji sample match apart from anti-aliasing differences
