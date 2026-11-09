# Spec Delta

## ADDED Requirements

### Requirement: All sessions stay attached

The client SHALL attach every session in the session list and keep each session's terminal updated with its output whether or not it is the active tab. Sessions that appear in a new `sessions` list SHALL be attached; sessions that disappear SHALL have their terminal state released. Only the active session's terminal SHALL be drawn. Switching tabs SHALL NOT reset or replay any session.

#### Scenario: Background output

- **WHEN** a background tab prints 100 lines and the user then selects it
- **THEN** all 100 lines are shown without a replay, including in its scrollback

#### Scenario: New session from browser

- **WHEN** a session is created from the browser client
- **THEN** Tabghostty attaches it as soon as it appears in the session list

#### Scenario: Removed session

- **WHEN** a session is deleted
- **THEN** Tabghostty releases that session's terminal state

### Requirement: All sessions share the window's grid size

Every session's terminal SHALL use the grid size of the window's terminal area, so that background output is laid out at the size it will be shown. When a session becomes live, and whenever the grid size changes, the client SHALL resize each live session's terminal and send a `resize` frame for each live session. When a session becomes active, the client SHALL send its current grid size again, because another client may have resized the PTY in the meantime.

#### Scenario: Window resized with background tabs

- **WHEN** three sessions are live and the user resizes the window
- **THEN** each of the three sessions receives one `resize` frame with the new grid size, and `stty size` in a background tab reports it

#### Scenario: Re-assert size on activation

- **WHEN** the browser client resized a session's PTY and the user then selects that tab in Tabghostty
- **THEN** Tabghostty sends a `resize` frame with its own grid size for that session
