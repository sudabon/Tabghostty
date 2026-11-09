# Spec Delta

## Purpose

Defines how users attach images to an agent's prompt by pasting or dropping them, by uploading them to the daemon and typing the stored file paths into the session.

## ADDED Requirements

### Requirement: Image sources

The client SHALL accept images from two sources:

- **Command-V paste**: an image on the pasteboard (PNG, or TIFF converted to PNG).
- **Drag-and-drop**: image files dropped onto the terminal area, where the image type is determined from the file content or type and limited to PNG, JPEG, GIF, and WebP.

While a drag that contains files is over the terminal area, the area SHALL show a dashed accent-colored drop frame with a light accent fill, and the frame SHALL disappear when the drag leaves or ends. Dropped files that are not supported images SHALL be ignored.

#### Scenario: Drop highlight

- **WHEN** the user drags a PNG file over the terminal
- **THEN** the dashed drop frame is shown until the file is dropped or the drag leaves

#### Scenario: Unsupported file

- **WHEN** the user drops a `.txt` file
- **THEN** nothing is uploaded or typed

### Requirement: Upload and type paths

For each image, in order, the client SHALL upload the raw image bytes with `POST /api/sessions/{id}/images` for the active session and collect the returned `path`. After all uploads finish, the client SHALL:

1. Escape each path by putting a backslash before every space, tab, newline, and each of the characters `` " ' \ $ ` & | ; < > ( ) * ? [ ] { } ! # ``.
2. Join the escaped paths with single spaces and append one trailing space.
3. Paste the result into the session through the normal paste path, including bracketed paste.

Failed uploads (for example larger than 10 MiB or rejected type) SHALL be skipped. If no upload succeeded, nothing SHALL be typed. If the active session changed while uploading, or the session is not live, nothing SHALL be typed.

#### Scenario: Paste a screenshot into Claude Code

- **WHEN** the user copies a screenshot and presses Command-V in Claude Code
- **THEN** the image is uploaded and its path followed by a space is entered into Claude Code's prompt

#### Scenario: Several files

- **WHEN** the user drops `a b.png` and `c.jpg`
- **THEN** both are uploaded and the typed text is the two returned paths, escaped, separated by a space, with a trailing space

#### Scenario: One failure

- **WHEN** one of two dropped images is rejected by the daemon
- **THEN** only the successful image's path is typed

#### Scenario: Tab switched during upload

- **WHEN** the user switches tabs before the upload finishes
- **THEN** no text is typed into either session
