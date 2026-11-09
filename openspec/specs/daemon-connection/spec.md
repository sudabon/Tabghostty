# daemon-connection Specification

## Purpose
Defines how Tabghostty finds, starts, authenticates with, and stays connected to the existing webtabinal daemon over its unchanged REST and WebSocket protocol.

## Requirements

### Requirement: Read daemon settings from the shared config file

The client SHALL read `port` and `auth_token` from `~/Library/Application Support/WebTabinal/config.json`. A missing or zero `port` SHALL mean the default port 8642. A `port` that is not an integer in 1–65535 SHALL be reported as a configuration error, and the client SHALL NOT connect to a guessed port.

#### Scenario: Default port

- **WHEN** the config file has no `port` field
- **THEN** the client connects to `127.0.0.1:8642`

#### Scenario: Invalid port

- **WHEN** the config file has `"port": true` or `"port": 70000`
- **THEN** the client shows a configuration error naming the config file and does not attempt a connection

### Requirement: Detect or start the daemon

On launch the client SHALL determine whether a webtabinal daemon is listening on the configured port by sending an unauthenticated `GET /api/config` and recognizing the daemon's `401` response signature. If no daemon is detected, the client SHALL start the daemon bundled inside the app (`webtabinal-daemon serve`) as a detached process that outlives the app, appending its stdout and stderr to `~/Library/Logs/WebTabinal/daemon.stdio.log`, and SHALL wait up to 15 seconds for it to start listening. If something other than the daemon is listening on the port, the client SHALL NOT start a second daemon and SHALL show an error naming the port.

#### Scenario: Daemon already running

- **WHEN** a daemon (for example one started by the browser workflow or by WebTabinal.app) is already listening
- **THEN** the client connects to it without starting another daemon

#### Scenario: Daemon not running

- **WHEN** nothing is listening on the configured port
- **THEN** the client starts the bundled daemon, connects once it is listening, and the daemon keeps running after the app quits

#### Scenario: Daemon fails to start

- **WHEN** the bundled daemon does not start listening within 15 seconds
- **THEN** the client shows an error that points to the daemon log file

#### Scenario: Foreign process on the port

- **WHEN** a process that is not the daemon answers on the configured port
- **THEN** the client does not start a daemon and shows an error naming the port

### Requirement: Authenticated requests

Every REST request and the WebSocket upgrade request SHALL carry `Authorization: Bearer <auth_token>` and SHALL address the daemon as `127.0.0.1:<port>`. The client SHALL NOT send an `Origin` header. The auth token SHALL NOT appear in logs, error messages, or user-visible text.

#### Scenario: WebSocket upgrade

- **WHEN** the client opens `ws://127.0.0.1:<port>/api/ws`
- **THEN** the upgrade request carries the Bearer token and no `Origin` header, and the daemon accepts it

#### Scenario: Token is never printed

- **WHEN** any request fails, including with `401 unauthorized`
- **THEN** neither the log output nor the error shown to the user contains the token value

### Requirement: Session list synchronization

The client SHALL treat each `sessions` frame as the complete, ordered list of sessions, replacing its previous list, and SHALL apply `state` and `agent_state` frames to the matching session. Session fields the client does not know SHALL be ignored, and frames of unknown type SHALL be ignored without disconnecting.

#### Scenario: Initial sync

- **WHEN** the WebSocket connection opens
- **THEN** the client's session list equals the daemon's `sessions` list in the daemon's order

#### Scenario: Unknown fields

- **WHEN** a `sessions` frame contains fields not known to the client
- **THEN** the frame is still applied and the unknown fields are ignored

### Requirement: Keepalive and reconnection

The client SHALL answer the daemon's WebSocket pings so the connection is not closed by the daemon's 60-second read deadline. When the connection is lost, the client SHALL reconnect with exponential backoff starting at 500 ms and capped at 5 seconds, and SHALL reset the backoff after a successful connection. The client SHALL keep reading frames promptly enough that the daemon does not disconnect it as a slow client during sustained output.

#### Scenario: Idle connection stays open

- **WHEN** the connection carries no session output for 5 minutes
- **THEN** the connection remains open

#### Scenario: Daemon restart

- **WHEN** the daemon is stopped and started again
- **THEN** the client reconnects without user action within 5 seconds of the daemon listening again

#### Scenario: Backoff growth

- **WHEN** consecutive reconnection attempts fail
- **THEN** the delays between attempts are approximately 0.5 s, 1 s, 2 s, 4 s, 5 s, 5 s, …
