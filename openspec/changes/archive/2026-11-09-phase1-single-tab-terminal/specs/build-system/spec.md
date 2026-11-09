# Spec Delta

## ADDED Requirements

### Requirement: App bundle with bundled daemon

The repository SHALL provide `make app`, which produces `build/Tabghostty.app` containing the Tabghostty executable and the webtabinal daemon at `Contents/MacOS/webtabinal-daemon`. The daemon SHALL come from a prebuilt binary given by `WEBTABINAL_DAEMON` when set, and otherwise be built from the webtabinal checkout at `WEBTABINAL_DIR` (default `../webtabinal`). The bundle SHALL declare macOS 14.0 as its minimum system version, use a bundle identifier distinct from WebTabinal.app, and record the webtabinal source revision it bundles. If no daemon binary can be obtained, the command SHALL fail with a message naming both variables.

#### Scenario: Build from sibling checkout

- **WHEN** `../webtabinal` exists and a developer runs `make app`
- **THEN** `build/Tabghostty.app/Contents/MacOS/webtabinal-daemon` exists and the bundle's Info.plist records the webtabinal revision

#### Scenario: Prebuilt daemon

- **WHEN** `WEBTABINAL_DAEMON=/path/to/webtabinal make app` is run
- **THEN** that binary is bundled and webtabinal is not built

#### Scenario: Daemon source missing

- **WHEN** neither `WEBTABINAL_DAEMON` nor a webtabinal checkout is available
- **THEN** `make app` exits non-zero and names `WEBTABINAL_DAEMON` and `WEBTABINAL_DIR`

#### Scenario: Coexists with WebTabinal.app

- **WHEN** both Tabghostty.app and WebTabinal.app are installed
- **THEN** macOS treats them as different applications (distinct bundle identifiers) and both can run at the same time

### Requirement: Fixture synchronization from webtabinal

The repository SHALL provide `make fixtures`, which copies webtabinal's `tests/fixtures/agents` into the repository's test fixtures and records the webtabinal revision it was copied from. Tests SHALL use the committed copy and SHALL NOT require a webtabinal checkout.

#### Scenario: Tests without webtabinal

- **WHEN** `make test` runs on a machine without a webtabinal checkout
- **THEN** the fixture-based tests run against the committed fixtures
