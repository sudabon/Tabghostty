# Spec Delta

## ADDED Requirements

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

The terminal engine SHALL retain at most the configured number of scrollback lines (`scrollback_lines`, default 10000) and discard older lines.

#### Scenario: Limit enforced

- **WHEN** a terminal configured with 100 scrollback lines receives 500 lines of output
- **THEN** at most 100 lines are retained above the visible screen

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
