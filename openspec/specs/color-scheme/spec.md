# color-scheme Specification

## Purpose
Defines how Tabghostty resolves and applies the light or dark color scheme to its terminals and surrounding interface, consistently with the daemon's terminal color replies.

## Requirements

### Requirement: Scheme resolution

The client SHALL use the light scheme when `color_scheme` is `light`, the dark scheme when it is `dark`, and, when it is `system`, the scheme matching the system appearance, following system appearance changes while running.

#### Scenario: Follow system

- **WHEN** `color_scheme` is `system` and the user switches macOS from Light to Dark
- **THEN** Tabghostty switches to the dark scheme without restarting

#### Scenario: Fixed scheme

- **WHEN** `color_scheme` is `light` and macOS is in Dark mode
- **THEN** Tabghostty uses the light scheme

### Requirement: Scheme applies everywhere

The resolved scheme SHALL apply at once to every terminal (default foreground, background, cursor, selection colors), the sidebar and other surrounding interface, and the window appearance. Changing the scheme from the settings window SHALL apply immediately and SHALL revert if saving fails.

#### Scenario: Switch from settings

- **WHEN** the user selects ライト in the settings window
- **THEN** all terminals and the sidebar switch to light colors immediately

#### Scenario: Save fails

- **WHEN** saving the new `color_scheme` fails
- **THEN** the previous scheme is restored and an error is shown
