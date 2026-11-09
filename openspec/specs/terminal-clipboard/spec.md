# terminal-clipboard Specification

## Purpose
Defines text selection in the terminal view and how text moves between the terminal, the system pasteboard, and the session.

## Requirements

### Requirement: Text selection

When the program has not enabled mouse reporting, or when the user holds Shift, dragging in the terminal view SHALL select text. Double-click SHALL select a word and triple-click SHALL select a line. The selection SHALL be drawn with the active color scheme's selection color (dark `#264f78`, light `#add6ff`) and SHALL extend into scrollback when the user drags past the top or bottom edge. Clicking without dragging SHALL clear the selection.

#### Scenario: Drag selection

- **WHEN** the user drags across two lines of output in a shell
- **THEN** those characters are highlighted with the selection color

#### Scenario: Word and line

- **WHEN** the user double-clicks a word and then triple-clicks a line
- **THEN** first the word and then the whole line is selected

#### Scenario: Shift overrides mouse reporting

- **WHEN** `vim` has enabled mouse reporting and the user Shift-drags
- **THEN** text is selected and no mouse report is sent

### Requirement: Copy with Command-C

Command-C SHALL copy the current selection to the system pasteboard as plain text (no escape sequences, wide-character spacer cells omitted, soft-wrapped lines joined, trailing spaces trimmed). Command-C SHALL never send bytes to the session, even when the selection is empty. Control-C SHALL continue to send `0x03`.

#### Scenario: Copy selection

- **WHEN** the user selects colored output and presses Command-C
- **THEN** the pasteboard contains the plain text of the selection

#### Scenario: No SIGINT from Command-C

- **WHEN** nothing is selected and the user presses Command-C while a command is running
- **THEN** nothing is sent to the session and the command keeps running

### Requirement: Copy on select

When `copy_on_select` is true, completing a non-empty selection SHALL copy it to the system pasteboard as if Command-C had been pressed. When it is false (the default), selecting SHALL NOT change the pasteboard.

#### Scenario: Enabled

- **WHEN** `copy_on_select` is true and the user finishes a drag selection
- **THEN** the pasteboard contains the selected text without pressing Command-C

### Requirement: Paste with Command-V

Command-V SHALL paste the pasteboard's text into the active session: line breaks (`\r\n` or `\n`) SHALL be sent as `\r`, and when the program has enabled bracketed paste (DECSET 2004) the text SHALL be wrapped in `ESC[200~` and `ESC[201~`. If the text is unsafe to paste — it contains a line break while bracketed paste is disabled, or it contains the bracketed-paste end sequence — the client SHALL ask the user to confirm before sending it. Paste SHALL be ignored while the session is not live.

#### Scenario: Bracketed multi-line paste

- **WHEN** zsh has bracketed paste enabled and the user pastes two lines
- **THEN** `cat -v` shows the text wrapped in `^[[200~` and `^[[201~` and the shell does not execute the lines

#### Scenario: Unsafe paste confirmation

- **WHEN** bracketed paste is disabled and the user pastes `rm -rf build\nls`
- **THEN** a confirmation is shown, and the text is sent only if the user confirms

#### Scenario: Cancelled unsafe paste

- **WHEN** the user cancels the confirmation
- **THEN** nothing is sent to the session

### Requirement: Control-V passes through

Control-V SHALL be sent to the session as `0x16` and SHALL NOT trigger a client-side paste, so agents that read the pasteboard themselves (Claude Code, Codex) keep working.

#### Scenario: Agent image paste

- **WHEN** the user presses Control-V in Codex
- **THEN** the session receives `0x16`

### Requirement: Edit menu

The app SHALL provide an Edit menu with Copy (Command-C) and Paste (Command-V). When the terminal view has focus they SHALL behave as Command-C and Command-V in the terminal; when a text field has focus they SHALL perform the text field's standard copy and paste.

#### Scenario: Menu copy

- **WHEN** text is selected in the terminal and the user chooses Edit > Copy
- **THEN** the selection is copied as with Command-C

### Requirement: OSC 52 clipboard access

A program's OSC 52 request to write the clipboard SHALL write the decoded text to the system pasteboard only when the session is live (never from replayed history). OSC 52 requests to read the clipboard SHALL be refused with no reply.

#### Scenario: Remote copy

- **WHEN** a program in a live session emits `OSC 52 ; c ; <base64 of "hello"> BEL`
- **THEN** the pasteboard contains `hello`

#### Scenario: Replayed clipboard write

- **WHEN** replay data contains an OSC 52 write
- **THEN** the pasteboard is not changed

#### Scenario: Read refused

- **WHEN** a program emits `OSC 52 ; c ; ? BEL`
- **THEN** no reply is sent to the session and the pasteboard is not read
