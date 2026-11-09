# Spec Delta

## Purpose

Defines the left sidebar that lists all daemon sessions as tabs, showing each session's location, command, run state, agent state, and unread status, plus the app-level unread badge.

## ADDED Requirements

### Requirement: Sidebar layout

The main window SHALL show a sidebar on the left listing every session in the daemon's order, with no top tab bar. The sidebar width SHALL start at `sidebar_width` (default 240 points). The user SHALL be able to drag the sidebar edge to resize it within 160–480 points; the new width SHALL be saved with `PATCH /api/config` when the drag ends. Below the list the sidebar SHALL show a "＋ 新規タブ" action and a "設定" action. The sidebar SHALL use the color tokens of the active color scheme (dark sidebar `#252526`, light `#f3f3f3`; active row dark `#2a2d2e`, light `#e4e6f1`).

#### Scenario: Resize persists

- **WHEN** the user drags the sidebar edge to 300 points and releases
- **THEN** `PATCH /api/config` is sent with `sidebar_width: 300` and the browser client uses 300 the next time it loads its configuration

#### Scenario: Clamp

- **WHEN** the user drags the sidebar edge beyond 480 points
- **THEN** the sidebar stops at 480 points

### Requirement: Three-row tab presentation

Each tab row SHALL show:

1. First line: the working directory's last path component (`~` for the home directory or an empty value, `/` for the root), then `◌` when the session's shell integration is off, then the unread dot when unread, then the agent state pill aligned to the trailing edge.
2. Second line: the session's command, or `zsh` when empty, truncated with an ellipsis and with the full command as a tooltip; dimmed unless the session is running.
3. Third line: `● running m:ss` (from `run_ms`) while running, `■ exit N` (`?` when unknown) when exited, `○ starting` when starting, otherwise `○ idle`; shown in the danger color whenever the last exit code is non-zero.

The active tab SHALL be highlighted and exited tabs SHALL be visually distinguished.

#### Scenario: Running command

- **WHEN** a session in `/Users/me/app` is running `npm test` for 75 seconds
- **THEN** its row shows `app`, `npm test`, and `● running 1:15`

#### Scenario: Failed command

- **WHEN** the last command exited with code 2 and the shell is idle
- **THEN** the third line is shown in the danger color

### Requirement: Agent state pill

The row SHALL show a pill with the lowercase agent state when the session's `agent_state` is `idle`, `working`, or `blocked`, and SHALL show no pill when it is `none` or missing. `working` SHALL use the accent style with a rotating indicator, which SHALL be static when the system's Reduce Motion setting is on; `blocked` SHALL use the danger style; `idle` SHALL use the muted style. The pill's accessibility label SHALL name the agent (Claude Code, Codex, Generic TUI, or the agent id) and the state. Pill changes SHALL NOT reorder tabs.

#### Scenario: Claude Code waiting for approval

- **WHEN** an `agent_state` frame sets a session to `blocked` with agent `claude`
- **THEN** that row shows a danger-styled `blocked` pill whose accessibility label is `Claude Code blocked`

#### Scenario: No agent

- **WHEN** a session's `agent_state` is `none`
- **THEN** its row shows no pill

### Requirement: Unread dots and Dock badge

A session SHALL become unread when it is not the active tab and a notification-eligible event occurs for it while `notification.enabled` is true. The eligible events are:

- A `state` frame that moves the session from `running` to `idle`, when `notification.min_duration_ms` is 0 or `run_ms` is at least that value.
- A `notify` frame whose title or body is not blank.

A session SHALL stay unread until the user selects it, and SHALL stop counting once it is removed from the session list. Mute and the notification command list SHALL NOT prevent the unread mark. The Dock icon badge SHALL show the number of unread sessions and SHALL be cleared when there are none.

#### Scenario: Background completion

- **WHEN** a command finishes in a non-active tab
- **THEN** that tab shows the unread dot and the Dock badge count increases by one

#### Scenario: Selecting clears

- **WHEN** the user selects an unread tab
- **THEN** its dot disappears and the badge count decreases by one

#### Scenario: Muted tab

- **WHEN** a muted non-active tab receives a `notify` frame
- **THEN** the tab becomes unread and is counted in the badge

#### Scenario: Closed tab

- **WHEN** an unread tab is closed
- **THEN** the badge count no longer includes it

### Requirement: Memo tooltip

When the pointer rests on a tab whose memo is not blank for 1 second, the memo SHALL be shown in a tooltip beside the tab. The tooltip SHALL hide when the pointer leaves, the memo editor opens, a drag starts, the sidebar scrolls, the window resizes, or a context menu opens.

#### Scenario: Hover

- **WHEN** the user hovers a tab whose memo is `レビュー対応` for 1 second
- **THEN** a tooltip showing `レビュー対応` appears next to the tab

### Requirement: Sidebar collapse

The user SHALL be able to collapse the sidebar with a button in the sidebar header, the View menu item "サイドバーを表示/隠す" (no key equivalent), and the toggle-sidebar chord. When collapsed, an expand button SHALL remain reachable over the terminal's top-leading corner. The terminal SHALL resize to the new width and receive keyboard focus after toggling. The collapsed state SHALL NOT be persisted across launches.

#### Scenario: Collapse from menu

- **WHEN** the user chooses View > サイドバーを表示/隠す
- **THEN** the sidebar hides, the terminal grows and sends a `resize`, and the terminal has keyboard focus

#### Scenario: Not persisted

- **WHEN** the user collapses the sidebar, quits, and relaunches
- **THEN** the sidebar is shown
