# Spec Delta

## ADDED Requirements

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
