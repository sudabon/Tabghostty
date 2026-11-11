# Spec Delta

## MODIFIED Requirements

### Requirement: Main window

On launch the app SHALL open one main window that shows the active session's terminal. The window title SHALL be `<directory> — Tabghostty`, where `<directory>` is the last path component of the active session's working directory (`~` for the home directory or an empty value, `/` for the root), or `Tabghostty` when there is no active session.

The window's frame (position and size) SHALL be remembered across launches:

- The app SHALL save the frame whenever the user moves or resizes the window, so the frame is kept however the app quits (closing the window, Command-Q, or closing the last tab).
- On the next launch, the window SHALL open with the saved frame, before the app connects to the daemon. This applies to the connecting and startup failure screens as well.
- When no frame has been saved, the window SHALL open at 1100×720 points, centered on the main screen.
- When the saved frame lies on a display that is no longer connected, the window SHALL open on a connected display with the saved size, limited to that display.

#### Scenario: Title follows directory

- **WHEN** the active session's working directory is `/Users/me/projects/app`
- **THEN** the window title is `app — Tabghostty`

#### Scenario: Frame restored

- **WHEN** the user moves and resizes the window, quits, and relaunches
- **THEN** the window reopens at the same position and size

#### Scenario: Frame restored after closing the window

- **WHEN** the user resizes the window to 900×600, closes it with the close button (which quits the app), and relaunches
- **THEN** the window reopens at 900×600 at the same position

#### Scenario: First launch

- **WHEN** the app is launched with no saved frame
- **THEN** the window opens at 1100×720 points, centered on the main screen

#### Scenario: Saved on a disconnected display

- **WHEN** the window was last placed on an external display that is disconnected before the next launch
- **THEN** the window opens on a connected display with its saved size and is fully visible
