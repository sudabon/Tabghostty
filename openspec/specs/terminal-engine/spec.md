# terminal-engine Specification

## Purpose
Defines the VT engine layer that turns a terminal byte stream into terminal state and exposes that state to the rest of Tabghostty, independent of rendering and transport.

## Requirements

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

### Requirement: Engine responses are delivered after the write completes

Responses and other effects the terminal engine produces while processing written bytes (PTY write-back such as DA/DSR replies, title changes, bell, clipboard requests, desktop notifications) SHALL be delivered to the rest of the client only after the write that produced them has returned, in the order they were produced. Handling an effect SHALL never write to the same terminal re-entrantly.

#### Scenario: DA1 reply

- **WHEN** `ESC[c` is written to the terminal
- **THEN** after the write returns, exactly one PTY write-back effect containing the primary device attributes reply is delivered

#### Scenario: Several queries in one write

- **WHEN** `ESC[c` and `ESC[6n` are written in one chunk
- **THEN** two write-back effects are delivered in that order after the write returns

### Requirement: Resize with cell pixel size

The terminal engine SHALL support resizing to a new column and row count together with the cell size in physical (device) pixels, and SHALL report that pixel size in response to size queries such as `CSI 14 t` and `CSI 16 t`.

#### Scenario: Retina cell size report

- **WHEN** the terminal is resized to 80×24 with a cell size of 16×34 device pixels and `ESC[16t` is written
- **THEN** the write-back reply reports a cell height of 34 and width of 16

### Requirement: Configurable scrollback limit

The terminal engine SHALL expose at most the configured number of scrollback lines (`scrollback_lines`, default 10000) above the visible screen. Lines older than that SHALL NOT be reachable through scrollback navigation, search, or text extraction. Because libghostty-vt discards scrollback only in whole pages, the engine MAY keep more lines than configured in memory; it SHALL still bound that memory by the configured line limit (page-granular).

#### Scenario: Limit enforced

- **WHEN** a terminal configured with 100 scrollback lines receives 500 lines of output
- **THEN** at most 100 lines are reported as available above the visible screen

#### Scenario: Older lines are not reachable

- **WHEN** more lines than the limit have scrolled off the screen
- **THEN** scrolling, search, and text extraction do not reach lines beyond the most recent `scrollback_lines` lines, even if the engine still holds them in memory

### Requirement: Serialized access per terminal

All operations on one terminal (writes, resizes, resets, render-state reads, encoder use) SHALL be serialized, so concurrent callers can never operate on the same terminal at the same time. Different terminals SHALL be usable independently.

#### Scenario: Concurrent producers

- **WHEN** output for a session and a resize for the same session are issued concurrently many times
- **THEN** no crash or data race occurs and the final content reflects all writes

### Requirement: Recorded agent streams are processed deterministically

The terminal engine SHALL process every recorded agent fixture stream (copied from webtabinal `tests/fixtures/agents`) at the fixture's recorded geometry without error, and the resulting plain-text screen SHALL be identical whether the stream is written in one chunk, in 24 KiB chunks (the daemon's replay chunk size), or one byte at a time.

#### Scenario: Chunking invariance on fixtures

- **WHEN** each fixture's `stream.raw` is written whole, in 24 KiB chunks, and byte by byte into three fresh terminals of the fixture's size
- **THEN** all three plain-text screens are identical
