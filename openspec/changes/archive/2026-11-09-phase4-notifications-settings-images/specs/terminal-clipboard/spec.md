# Spec Delta

## MODIFIED Requirements

### Requirement: Paste with Command-V

Command-V SHALL first check the pasteboard for an image (PNG, or TIFF converted to PNG). If one is present, it SHALL be attached as defined by the image-attach capability and no text SHALL be pasted. Otherwise Command-V SHALL paste the pasteboard's text into the active session: line breaks (`\r\n` or `\n`) SHALL be sent as `\r`, and when the program has enabled bracketed paste (DECSET 2004) the text SHALL be wrapped in `ESC[200~` and `ESC[201~`. If the text is unsafe to paste — it contains a line break while bracketed paste is disabled, or it contains the bracketed-paste end sequence — the client SHALL ask the user to confirm before sending it. Paste SHALL be ignored while the session is not live.

#### Scenario: Bracketed multi-line paste

- **WHEN** zsh has bracketed paste enabled and the user pastes two lines
- **THEN** `cat -v` shows the text wrapped in `^[[200~` and `^[[201~` and the shell does not execute the lines

#### Scenario: Unsafe paste confirmation

- **WHEN** bracketed paste is disabled and the user pastes `rm -rf build\nls`
- **THEN** a confirmation is shown, and the text is sent only if the user confirms

#### Scenario: Cancelled unsafe paste

- **WHEN** the user cancels the confirmation
- **THEN** nothing is sent to the session

#### Scenario: Image takes precedence

- **WHEN** the pasteboard holds both an image and text and the user presses Command-V
- **THEN** the image is attached and the text is not pasted
