# Spec Delta

## Purpose

Defines how pointer and scroll input in the terminal view is reported to programs or used to navigate scrollback.

## ADDED Requirements

### Requirement: Mouse reporting

When a program enables mouse reporting (X10, normal, button-event, or any-event tracking), mouse button presses, releases, drags, and — for any-event tracking — motion in the terminal view SHALL be sent to the session using the encoding the program selected (including SGR 1006). When the program enables pixel-position reporting (DECSET 1016), positions SHALL be reported in device pixels relative to the terminal's top-left cell. Mouse reports SHALL only be sent while the session is live. Mouse input SHALL NOT be reported while the user holds Shift (it selects text instead).

#### Scenario: Click in vim

- **WHEN** `vim` runs with `:set mouse=a` and the user clicks a character
- **THEN** vim moves its cursor to that character

#### Scenario: SGR encoding

- **WHEN** a program has enabled DECSET 1000 and 1006 and the user clicks cell column 10, row 5
- **THEN** the session receives `ESC[<0;10;5M` followed by `ESC[<0;10;5m` on release

#### Scenario: Pixel positions

- **WHEN** a program has enabled DECSET 1016 and the user clicks
- **THEN** the reported coordinates are device-pixel positions within the terminal grid

### Requirement: Scroll wheel and trackpad

Scrolling in the terminal view SHALL be handled in this order:

1. If the program has enabled mouse reporting, wheel events SHALL be reported to the program.
2. Otherwise, if the alternate screen is active, scrolling SHALL send Up or Down arrow key sequences (one per scrolled line, honoring application cursor mode), as the web client does.
3. Otherwise, scrolling SHALL move the viewport through scrollback.

Precise (trackpad) deltas SHALL be accumulated so that slow scrolling still moves by whole lines. Output arriving while the viewport is scrolled back SHALL NOT move the viewport.

#### Scenario: Scrollback in a shell

- **WHEN** the user scrolls up with the trackpad in a shell with long history
- **THEN** earlier output becomes visible and nothing is sent to the session

#### Scenario: Pager in alternate screen

- **WHEN** `less` is running without mouse reporting and the user scrolls down three lines
- **THEN** the session receives three Down-arrow sequences

#### Scenario: Program with mouse reporting

- **WHEN** `htop` has enabled mouse reporting and the user scrolls
- **THEN** wheel events are reported to htop and the viewport does not move

#### Scenario: Output while scrolled back

- **WHEN** the user is viewing scrollback and new output arrives
- **THEN** the viewport stays on the lines the user is viewing
