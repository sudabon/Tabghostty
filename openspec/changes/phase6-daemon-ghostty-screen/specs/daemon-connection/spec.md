# Spec Delta

## ADDED Requirements

### Requirement: Binary output frames

The client SHALL include `"binary": true` in every `attach` frame. It SHALL accept session output and replay data both as JSON text frames (`output`, `replay` with base64 data) and as binary WebSocket messages in the format defined by the daemon's binary frame specification, and SHALL process both in the order received. A daemon that ignores the `binary` field SHALL continue to work with the client unchanged, through JSON frames.

#### Scenario: Daemon with binary support

- **WHEN** the daemon supports binary frames and a session produces output
- **THEN** the client receives binary messages for that session and the terminal shows the same content as with JSON frames

#### Scenario: Older daemon

- **WHEN** the daemon does not support binary frames
- **THEN** the client receives JSON `output` and `replay` frames and works as before

#### Scenario: Replay completion in binary

- **WHEN** a binary replay message marks the end of the replay
- **THEN** the session enters the live phase exactly as with a JSON `replay` frame with `done: true`
