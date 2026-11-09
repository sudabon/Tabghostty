# Spec Delta

## MODIFIED Requirements

### Requirement: App bundle with bundled daemon

The repository SHALL provide `make app`, which produces `build/Tabghostty.app` containing the Tabghostty executable and the daemon at `Contents/MacOS/webtabinal-daemon`. The daemon SHALL come from a prebuilt binary given by `WEBTABINAL_DAEMON` when set, and otherwise be built from the repository's `daemon/` with the `ghostty` build tag. The browser UI embedded in the daemon SHALL be built from the webtabinal checkout at `WEBTABINAL_DIR` (default `../webtabinal`) when one is available; otherwise the command SHALL warn and bundle the daemon with its placeholder page. The bundle SHALL declare macOS 14.0 as its minimum system version, use a bundle identifier distinct from WebTabinal.app, and record the source revision of the daemon it bundles.

#### Scenario: Build from sibling checkout

- **WHEN** `../webtabinal` exists and a developer runs `make app`
- **THEN** `build/Tabghostty.app/Contents/MacOS/webtabinal-daemon` is built from `daemon/` with the ghostty screen model, embeds the browser UI built from `../webtabinal`, and the bundle's Info.plist records the Tabghostty revision the daemon came from

#### Scenario: Prebuilt daemon

- **WHEN** `WEBTABINAL_DAEMON=/path/to/webtabinal make app` is run
- **THEN** that binary is bundled and `daemon/` is not built

#### Scenario: Daemon source missing

- **WHEN** neither `WEBTABINAL_DAEMON` nor a webtabinal checkout is available
- **THEN** `make app` still builds the daemon from `daemon/`, warns that the browser UI is a placeholder, and names `WEBTABINAL_DIR`

#### Scenario: Coexists with WebTabinal.app

- **WHEN** both Tabghostty.app and WebTabinal.app are installed
- **THEN** macOS treats them as different applications (distinct bundle identifiers) and both can run at the same time

### Requirement: Fixture synchronization from webtabinal

The repository SHALL provide `make fixtures`, which copies the bundled daemon's `daemon/tests/fixtures/agents` (originally from webtabinal), including any reference screens, into the repository's test fixtures and records the revision it was copied from. Tests SHALL use the committed copy and SHALL NOT require a webtabinal checkout.

#### Scenario: Tests without webtabinal

- **WHEN** `make test` runs on a machine without a webtabinal checkout
- **THEN** the fixture-based tests run against the committed fixtures
