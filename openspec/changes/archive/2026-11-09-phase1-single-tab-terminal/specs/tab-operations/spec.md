# Spec Delta

## Purpose

Defines which session is active in the client and how sessions are created and changed through the daemon's REST API.

## ADDED Requirements

### Requirement: Active session selection

The client SHALL have at most one active session, shown in the main window. When a `sessions` list arrives, the active session SHALL stay active if it is still listed; otherwise the first session in the list SHALL become active, or none if the list is empty. This selection is local to the client and SHALL NOT affect other clients connected to the same daemon.

#### Scenario: Active session removed elsewhere

- **WHEN** the active session is closed from the browser client
- **THEN** the first remaining session in the daemon's order becomes active in Tabghostty

#### Scenario: Independent clients

- **WHEN** the browser client and Tabghostty show different sessions
- **THEN** neither client's active session changes because of the other

### Requirement: Bootstrap a usable session on startup

After the first `sessions` list following launch, the client SHALL ensure there is a usable session: if the list is empty it SHALL create one with `POST /api/sessions`; if the session that would become active has exited, it SHALL restart it with `POST /api/sessions/{id}/restart`. The resulting session SHALL become active. This SHALL happen only once per launch, not on reconnects.

#### Scenario: No sessions

- **WHEN** the app launches against a daemon with no sessions
- **THEN** a new session is created in the home directory and shown

#### Scenario: Exited first session

- **WHEN** the app launches and the first session has exited
- **THEN** that session is restarted and the new session is shown

#### Scenario: Reconnect does not create sessions

- **WHEN** the connection drops and reconnects while the daemon has no sessions
- **THEN** no session is created by the reconnect
