# Spec Delta

## Purpose

Defines the VT engine layer that turns a terminal byte stream into terminal state and exposes that state to the rest of Tabghostty, independent of rendering and transport.

## ADDED Requirements

### Requirement: Byte stream to terminal state

The terminal engine SHALL accept arbitrary chunks of VT-encoded bytes and update its terminal state accordingly. The resulting state SHALL NOT depend on how the byte stream is split into chunks, including splits inside an escape sequence or inside a multi-byte UTF-8 character.

#### Scenario: Styled text

- **WHEN** the bytes `Hello\r\n\x1b[31mRed\x1b[0m` are written to a new terminal
- **THEN** the terminal's plain-text content is `Hello` on the first line and `Red` on the second line

#### Scenario: Escape sequence split across writes

- **WHEN** `Hello\r\n\x1b[3` and `1mRed\x1b[0m` are written as two separate chunks
- **THEN** the plain-text content is identical to writing the same bytes in one chunk

#### Scenario: UTF-8 character split across writes

- **WHEN** the three bytes of `が` are written as two separate chunks
- **THEN** the plain-text content contains `が` and no replacement character

### Requirement: Plain-text extraction

The terminal engine SHALL provide the terminal's screen content as plain text without any escape sequences or styling, with one line per terminal row and trailing blank cells removed.

#### Scenario: Styling is dropped

- **WHEN** text containing SGR color and bold sequences is written and plain text is requested
- **THEN** the returned text contains only the printable characters, with no escape bytes
