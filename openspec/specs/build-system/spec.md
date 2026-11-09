# build-system Specification

## Purpose
Defines how a developer obtains the libghostty-vt dependency, builds, and tests Tabghostty from a fresh clone in a reproducible and verifiable way.

## Requirements

### Requirement: Verified libghostty-vt acquisition

The repository SHALL provide a single command (`make deps`) that obtains libghostty-vt at the version pinned in the repository and places it at a fixed vendor location. The command SHALL verify the downloaded artifact against a checksum pinned in the repository, and against the upstream signature when upstream publishes one, before placing it. On any verification failure the command SHALL exit non-zero and SHALL leave no partially placed artifact.

#### Scenario: Fresh clone

- **WHEN** a developer runs `make deps` in a fresh clone with network access
- **THEN** the pinned libghostty-vt version is placed at the vendor location and the command exits 0

#### Scenario: Checksum mismatch

- **WHEN** the downloaded artifact does not match the pinned checksum
- **THEN** the command exits non-zero with a message naming the mismatch, and the vendor location does not contain the new artifact

#### Scenario: Already present

- **WHEN** `make deps` is run again and the vendor location already holds the verified pinned version
- **THEN** the command does not download again and exits 0

### Requirement: Vendored binaries stay out of version control

Downloaded or locally built libghostty-vt artifacts and SwiftPM build outputs SHALL be excluded from version control.

#### Scenario: Clean status after setup

- **WHEN** a developer runs `make deps` and `make build` in a clean checkout
- **THEN** `git status` reports no untracked or modified files

### Requirement: Minimum macOS version

Tabghostty SHALL declare macOS 14 as its minimum supported operating system.

#### Scenario: Package platform

- **WHEN** the package manifest is inspected
- **THEN** the declared macOS platform minimum is 14

### Requirement: Developer build and test commands

The repository SHALL provide `make build` to compile all targets and `make test` to run the automated test suite. Both SHALL work with the Xcode Command Line Tools alone (no full Xcode installation). When the libghostty-vt artifact is missing, both commands SHALL fail with a message instructing the developer to run `make deps`.

#### Scenario: Tests run with Command Line Tools only

- **WHEN** a developer with only the Command Line Tools installed runs `make deps` then `make test`
- **THEN** the test suite runs and reports its results

#### Scenario: Missing dependency

- **WHEN** a developer runs `make build` or `make test` before `make deps`
- **THEN** the command exits non-zero and tells the developer to run `make deps`

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
