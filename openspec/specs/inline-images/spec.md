# inline-images Specification

## Purpose
Defines which inline image protocols the terminal view displays and how unsupported image protocols are handled.

## Requirements

### Requirement: Kitty graphics protocol

Images transmitted and placed with the kitty graphics protocol SHALL be displayed at their placement position and size, scaled according to the device-pixel cell size, layered relative to text as the placement requests, scrolled together with the text they are attached to, and removed when deleted or when the screen region holding them is cleared. Images in background sessions SHALL appear when the session is selected.

#### Scenario: Agent screenshot preview

- **WHEN** a program displays a PNG with the kitty graphics protocol
- **THEN** the image appears at the cursor position at the expected size on both Retina and non-Retina displays

#### Scenario: Scrolled away

- **WHEN** output scrolls the image off the top of the screen and the user scrolls back
- **THEN** the image is visible again in scrollback at its original position

### Requirement: Unsupported image protocols

Sixel and iTerm2 inline image (OSC 1337 File) sequences SHALL NOT be displayed as images. Receiving them SHALL NOT corrupt the display, leave stray characters, or affect the terminal's subsequent state.

#### Scenario: Sixel

- **WHEN** a program outputs a Sixel image followed by the text `done`
- **THEN** no image is shown, no escape debris is displayed, and `done` appears at the expected position
