# Spec Delta

## Purpose

Defines when Tabghostty shows macOS notifications for command completion and agent attention events, what they contain, and how clicking them returns the user to the session.

## ADDED Requirements

### Requirement: Notification decision

For each completion event (a session's state changes from `running` to `idle`) and each wait event (a `notify` frame whose trimmed title or body is not empty), the client SHALL decide whether to show a notification in this order:

1. If `notification.enabled` is false, show nothing.
2. If the session is the active tab, the window is focused, and `notification.always` is false, show nothing.
3. For completion events only, if `notification.min_duration_ms` is greater than 0 and `run_ms` is below it, show nothing.
4. Mark the session unread when it is not the active tab.
5. If the session is muted (`notifications_muted`), show nothing.
6. If `notification.commands` is not empty and the lowercased basename of the first whitespace-separated token of the session's command does not exactly match a trimmed, lowercased entry, show nothing. A session with an empty command SHALL NOT match.
7. Otherwise show the notification.

The client SHALL NOT use the `kind` or `source` fields to change this decision. Deduplication across signals remains the daemon's responsibility.

#### Scenario: Focused active tab

- **WHEN** a command finishes in the active tab while the window is focused and `always` is false
- **THEN** no notification is shown

#### Scenario: Always

- **WHEN** the same happens with `always` true
- **THEN** a notification is shown

#### Scenario: Short command

- **WHEN** `min_duration_ms` is 5000 and a command finishes after 2 seconds in a background tab
- **THEN** no notification is shown and the tab is not marked unread

#### Scenario: Wait ignores min duration

- **WHEN** `min_duration_ms` is 5000 and a `notify` frame arrives for a background tab
- **THEN** the notification is shown

#### Scenario: Command list

- **WHEN** `commands` is `["claude", "codex"]` and the session's command is `/opt/homebrew/bin/Claude --resume`
- **THEN** the notification is shown

#### Scenario: Not in command list

- **WHEN** `commands` is `["claude"]` and the session's command is `npm test`
- **THEN** no notification is shown but the background tab is marked unread

#### Scenario: Muted

- **WHEN** a muted background tab receives a `notify` frame
- **THEN** no notification is shown and the tab is marked unread

### Requirement: Notification content

A completion notification's title SHALL be `✓ <command>` when the exit code is 0 or unknown, otherwise `✗ <command> (exit N)`. Its body SHALL be `<directory> ・ <seconds>s`, where `<directory>` is the working directory's last path component and `<seconds>` is `run_ms` divided by 1000 and rounded. A wait notification SHALL use the frame's trimmed title and body; an empty title SHALL fall back to the session's command, then to `Tabghostty`. Notifications SHALL play no sound.

#### Scenario: Failed build

- **WHEN** `make` exits with code 2 after 12.4 seconds in `/Users/me/app`
- **THEN** the notification title is `✗ make (exit 2)` and the body is `app ・ 12s`

#### Scenario: Hook notification

- **WHEN** a `notify` frame arrives with title `Claude Code` and body `Turn complete`
- **THEN** the notification shows that title and body

### Requirement: Delivery and activation

Notifications SHALL be delivered through the macOS user notification system, identify their session, and be presented as a banner and in Notification Center even when Tabghostty is frontmost. Clicking a notification SHALL bring Tabghostty to the front, show its window, and make that session the active tab if it still exists; if the click arrives before the session list is loaded, the selection SHALL be applied once it is.

#### Scenario: Click selects the tab

- **WHEN** the user clicks a notification for a background session
- **THEN** Tabghostty comes to the front with that session active

#### Scenario: Session gone

- **WHEN** the user clicks a notification for a session that has since been closed
- **THEN** Tabghostty comes to the front and the active tab does not change

#### Scenario: CLI turn notification

- **WHEN** an agent's stop hook runs `webtabinal notify --title "Claude Code" --body "Turn complete"` in a background tab
- **THEN** a notification is shown and clicking it selects that tab

### Requirement: User-initiated authorization

The client SHALL NOT request notification permission automatically. The settings window SHALL show the current permission state and, only while the state is undetermined, a button that requests permission. The displayed state SHALL be refreshed when the settings window opens and when the app becomes active. When permission is denied, the client SHALL still mark tabs unread and update the Dock badge.

#### Scenario: First request

- **WHEN** permission is undetermined and the user clicks 通知を許可
- **THEN** macOS asks for permission and the displayed state updates to the result

#### Scenario: Denied

- **WHEN** permission is denied and a background command finishes
- **THEN** no notification appears but the tab is marked unread and counted in the Dock badge
