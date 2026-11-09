# app-shell Specification

## Purpose
Defines the native application frame around the terminal: window, menus, startup and error presentation, and how quitting relates to the daemon.

## Requirements

### Requirement: Main window

On launch the app SHALL open one main window (initially 1100×720 points, with its frame remembered across launches) that shows the active session's terminal. The window title SHALL be `<directory> — Tabghostty`, where `<directory>` is the last path component of the active session's working directory (`~` for the home directory or an empty value, `/` for the root), or `Tabghostty` when there is no active session.

#### Scenario: Title follows directory

- **WHEN** the active session's working directory is `/Users/me/projects/app`
- **THEN** the window title is `app — Tabghostty`

#### Scenario: Frame restored

- **WHEN** the user moves and resizes the window, quits, and relaunches
- **THEN** the window reopens at the same position and size

### Requirement: Quitting keeps the daemon running

Closing the last window SHALL quit the app. Quitting the app SHALL NOT stop the daemon or any session.

#### Scenario: Close and reopen

- **WHEN** the user closes the window while a long-running command is running and later relaunches the app
- **THEN** the command is still running and its output is shown after replay

### Requirement: Application menu

The app SHALL provide an application menu with About, Hide, Hide Others, Show All, and Quit items with their standard key equivalents.

#### Scenario: Quit shortcut

- **WHEN** the user presses Command-Q
- **THEN** the app quits and the daemon keeps running

### Requirement: Startup failure screen

If the app cannot read the configuration, detect or start the daemon, or load the daemon's configuration, the window SHALL show a startup failure screen with the error message (never containing the auth token) and a retry action that repeats startup.

#### Scenario: Retry after starting the daemon manually

- **WHEN** startup failed because the daemon could not be reached, the user starts it, and chooses retry
- **THEN** the app connects and shows the terminal

### Requirement: Transient error messages

Error frames from the daemon and failed user-initiated requests SHALL be shown as a transient, non-modal message in the window that disappears after 5 seconds or when dismissed.

#### Scenario: Attach overflow notice

- **WHEN** an `attach_overflow` error frame arrives
- **THEN** its message is shown transiently while the session re-attaches

### Requirement: Application icon

The app bundle SHALL include an application icon generated from the repository's icon source, shown in the Dock, Finder, and the app switcher.

#### Scenario: Dock icon

- **WHEN** Tabghostty.app is launched from `/Applications`
- **THEN** the Dock shows the Tabghostty icon rather than the generic application icon

### Requirement: Version information in About

The About panel SHALL show the Tabghostty version and the revision of the webtabinal daemon bundled in the app.

#### Scenario: Check bundled daemon

- **WHEN** the user opens About Tabghostty
- **THEN** the panel shows the app version and the bundled daemon revision recorded at build time
