# Spec Delta

## Purpose

Defines in-terminal text search over the active session's screen and scrollback.

## ADDED Requirements

### Requirement: Find bar

Command-F SHALL open a find bar above the active terminal with the search field focused. Escape or the close button SHALL close it and return keyboard focus to the terminal. While the find bar has focus, keystrokes SHALL go to the search field and SHALL NOT be sent to the session.

#### Scenario: Open and close

- **WHEN** the user presses Command-F, types `error`, and presses Escape
- **THEN** the find bar closes, the terminal regains focus, and nothing was sent to the session

### Requirement: Search scope and matching

Searching SHALL cover the active session's scrollback and screen and SHALL be case-insensitive. All matches SHALL be highlighted, the current match SHALL be highlighted distinctly and scrolled into view, and the find bar SHALL show the current match position and total count (for example `3 / 12`). Results SHALL update as the query changes and as new output arrives.

#### Scenario: Matches in scrollback

- **WHEN** the query `ERROR` matches 12 lines, 10 of them in scrollback
- **THEN** the bar shows `1 / 12` and the viewport scrolls to show the first match

#### Scenario: No match

- **WHEN** the query matches nothing
- **THEN** the bar shows `0 / 0` and the viewport does not move

### Requirement: Match navigation

Enter or Command-G SHALL move to the next match and Shift-Enter or Command-Shift-G to the previous match, wrapping around at either end.

#### Scenario: Wrap

- **WHEN** the current match is the last one and the user presses Command-G
- **THEN** the first match becomes current
