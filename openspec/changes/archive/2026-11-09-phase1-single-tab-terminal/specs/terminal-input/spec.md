# Spec Delta

## Purpose

Defines how user keyboard input in the terminal view is translated into bytes and delivered to the session's PTY through the daemon.

## ADDED Requirements

### Requirement: Key events are encoded by the terminal's current modes

Key presses in the focused terminal view SHALL be translated to bytes according to the terminal's current input modes (for example application cursor keys) and sent to the displayed session as `input` frames. At minimum, printable characters, Enter, Backspace, Tab, Escape, arrow keys, Home/End, Page Up/Down, Delete, function keys, and Control-letter combinations SHALL be delivered. Key combinations with the Command modifier SHALL NOT be sent to the session.

#### Scenario: Typing a command

- **WHEN** the user types `ls` and presses Enter in a live session
- **THEN** the shell receives `ls\r` and runs the command

#### Scenario: Interrupt

- **WHEN** the user presses Control-C in a live session
- **THEN** the session receives byte `0x03`

#### Scenario: Application cursor mode

- **WHEN** a program has enabled application cursor keys and the user presses Up
- **THEN** the session receives `ESC O A`

#### Scenario: Command shortcuts are not typed

- **WHEN** the user presses Command-Q or another Command combination
- **THEN** no `input` frame is sent for that key

### Requirement: Input batching and gating

Input produced for a session within the same run-loop turn SHALL be sent as a single `input` frame with base64-encoded bytes, preserving order. Input SHALL be sent only while the session is live; input produced while the session is replaying or while the connection is down SHALL be dropped, not queued.

#### Scenario: Fast typing

- **WHEN** several bytes are produced for a session within one run-loop turn
- **THEN** they are sent in one `input` frame in the original order

#### Scenario: Disconnected

- **WHEN** the user types while the WebSocket is disconnected
- **THEN** the keystrokes are dropped and are not delivered after reconnecting
