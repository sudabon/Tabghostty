# Spec Delta

## Purpose

Verifies that Tabghostty's terminal engine and the daemon's screen model produce the same screen for recorded agent streams, so that agent state detection and what the user sees agree.

## ADDED Requirements

### Requirement: Fixture screens match the daemon's ghostty screen model

For every agent fixture that has a daemon-generated reference screen (`screen.txt`, produced by the daemon's libghostty-based screen model), Tabghostty's terminal engine SHALL produce the same visible screen when the fixture's stream is written at the fixture's geometry. Before comparison, Tabghostty SHALL normalize its screen the same way the daemon does: visible rows only, trailing spaces trimmed, wide-character continuation cells skipped, and combining marks kept with their base character.

#### Scenario: Fixture parity

- **WHEN** the test suite writes each fixture's `stream.raw` into a terminal of the fixture's size and normalizes the visible screen
- **THEN** the result equals that fixture's `screen.txt` line for line

#### Scenario: Reference missing

- **WHEN** a fixture has no `screen.txt`
- **THEN** the parity test reports the fixture as skipped and does not fail

### Requirement: Reference screens are reproducible

The reference screens SHALL be generated only by the bundled daemon's tooling (`daemon/`, see bundled-daemon「Reference screen generation」), and the copy used by Tabghostty SHALL record the daemon revision and libghostty-vt version that produced it. The libghostty-vt version Tabghostty links SHALL be the same version that produced the reference screens; a mismatch SHALL be reported by the parity test instead of silently comparing.

#### Scenario: Version mismatch

- **WHEN** Tabghostty links a libghostty-vt version different from the one recorded with the reference screens
- **THEN** the parity test fails with a message naming both versions
