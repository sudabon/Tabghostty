# Spec Delta

## Purpose

The daemon that Tabghostty.app bundles lives in this repository under `daemon/`, copied from webtabinal without modifying webtabinal. This capability covers what the bundled daemon adds on top of its upstream: a libghostty-vt screen model, binary output frames, and reference screens for engine parity.

## ADDED Requirements

### Requirement: Daemon source in the repository

The repository SHALL contain the daemon's Go module under `daemon/`, copied from a recorded webtabinal revision. `daemon/UPSTREAM.md` SHALL record that revision, the copied paths, every file the repository adds or changes relative to the upstream copy, and the procedure for taking in later upstream changes. Building, testing, or bundling the daemon SHALL NOT modify webtabinal's source files.

#### Scenario: Upstream record

- **WHEN** a developer reads `daemon/UPSTREAM.md`
- **THEN** it names the webtabinal revision the copy came from and lists each locally added or changed file

#### Scenario: webtabinal stays unchanged

- **WHEN** `make app` runs with a webtabinal checkout present
- **THEN** `git status` in the webtabinal checkout shows no changes to tracked files

### Requirement: libghostty-vt screen model

When built with the `ghostty` build tag, the daemon's screen model SHALL use libghostty-vt (through `go.mitchellh.com/libghostty` pinned to a fixed revision, linked against the repository's vendored libghostty-vt) and SHALL produce snapshots normalized the same way as the default model: visible rows only, trailing spaces trimmed, wide-character continuation cells skipped, and combining marks kept with their base character. Without the tag, the daemon SHALL build as pure Go with its original screen model. The screen model's conformance, contract, agent-detection, and session tests SHALL pass in both builds.

#### Scenario: Ghostty build passes the screen model tests

- **WHEN** `go test -race -tags ghostty ./internal/vtscreen/... ./internal/agentdetect/... ./internal/session/...` runs in `daemon/`
- **THEN** all tests pass, including the conformance cases

#### Scenario: Default build unchanged

- **WHEN** `go test ./...` runs in `daemon/` without build tags
- **THEN** all tests pass and no cgo or libghostty-vt is required

### Requirement: Binary output frames format

When a client's `attach` frame for a session includes `"binary": true`, the daemon SHALL send that session's `replay` and `output` data to that connection as binary WebSocket messages until the client attaches the session again. Each message SHALL be: one byte kind (`0x01` output, `0x02` replay chunk with more to follow, `0x03` final replay chunk), one byte sid length N (1–255), N bytes of ASCII sid, then the raw PTY bytes. An empty replay SHALL be sent as a single `0x03` message with no data. All other frames, and all frames for sessions attached without the flag, SHALL remain JSON text frames. A session whose id cannot be encoded this way SHALL be sent as JSON.

#### Scenario: Client declares binary

- **WHEN** a client attaches with `"binary": true` and the session then produces output
- **THEN** the client receives the replay as `0x02`… `0x03` messages followed by `0x01` messages carrying the raw bytes

#### Scenario: Client does not declare binary

- **WHEN** a client attaches without the field
- **THEN** it receives JSON `replay` and `output` frames exactly as before

#### Scenario: Output buffered during attach

- **WHEN** output arrives while the replay for a binary attach is being sent
- **THEN** the buffered output is delivered after the final replay message as binary `0x01` messages

### Requirement: Reference screen generation

The daemon's test suite SHALL provide an `-update-screens` flag that, in a `ghostty`-tagged build, replays every agent fixture through the screen model at the fixture's geometry and writes the final active screen to `screen.txt` (one line per row, each followed by `\n`) and `screen.meta.json` (`screen_model` and the runtime `libghostty_vt_version`) in the fixture's directory. Without the `ghostty` tag the flag SHALL NOT write reference screens. In a `ghostty`-tagged build without the flag, the suite SHALL fail if a committed `screen.txt` differs from the screen model's current output.

#### Scenario: Generate reference screens

- **WHEN** `make screens` runs
- **THEN** every fixture directory under `daemon/tests/fixtures/agents` contains a `screen.txt` and a `screen.meta.json` with `"screen_model": "ghostty"`

#### Scenario: Stale reference

- **WHEN** the screen model changes so that a fixture's final screen differs from its committed `screen.txt`
- **THEN** the `ghostty`-tagged test run fails and names that fixture

### Requirement: Daemon build commands

The repository SHALL provide `make daemon`, which builds the daemon from `daemon/` with the `ghostty` tag against the vendored libghostty-vt, and `make daemon-test`, which runs the daemon's tests in both the default and the `ghostty`-tagged builds. Neither SHALL require `pkg-config` or Zig to be installed. When the vendored libghostty-vt is missing, both SHALL fail with a message instructing the developer to run `make deps`.

#### Scenario: Build with Command Line Tools and Go

- **WHEN** a developer with the Command Line Tools and Go installed runs `make deps` then `make daemon`
- **THEN** `daemon/bin/webtabinal` is built and its embedded build settings (`go version -m`) show the `ghostty` tag
