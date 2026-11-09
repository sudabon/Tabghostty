# terminal-rendering Specification

## Purpose
Defines how a session's terminal state is drawn in the native view — cells, colors, fonts, cursor, and the mapping between view size and terminal grid — so it looks the same as the web client.

## Requirements

### Requirement: Font resolution from the configured font stack

The terminal view SHALL derive its font from `font_family` and `font_size` (defaults `Menlo, Monaco, 'Courier New', monospace` and 14). `font_family` is a CSS-style comma-separated list: entries SHALL be trimmed and unquoted, and the first installed family SHALL be used; `monospace` SHALL map to the system monospaced font. Bold and italic SHALL use the corresponding traits of the chosen family. Characters the chosen font cannot render (CJK, emoji, symbols) SHALL be drawn with a system fallback font.

#### Scenario: First installed family wins

- **WHEN** `font_family` is `NoSuchFont, Menlo, monospace`
- **THEN** the terminal renders with Menlo

#### Scenario: Generic monospace

- **WHEN** `font_family` is `monospace`
- **THEN** the terminal renders with the system monospaced font

#### Scenario: Fallback glyphs

- **WHEN** output contains `日本語` and `👨‍👩‍👧` and the chosen font lacks those glyphs
- **THEN** the characters are drawn with a fallback font rather than as missing-glyph boxes

### Requirement: Cell drawing

The terminal view SHALL draw each cell's character with its foreground and background colors and its bold, italic, underline, strikethrough, inverse, faint, and invisible attributes. Wide characters SHALL occupy two cells. The colors SHALL come from the active color scheme: the default foreground, background, and cursor colors SHALL equal the values the daemon reports for OSC 10/11/12 (dark: foreground `#cccccc`, background `#1e1e1e`, cursor `#ffffff`; light: foreground `#333333`, background `#ffffff`, cursor `#000000`), the 16 ANSI colors SHALL equal the web client's (xterm.js default) palette, and 256-color and 24-bit colors SHALL be supported. Foreground colors SHALL be adjusted to reach a minimum contrast ratio of 4.5 against their background, as the web client does.

#### Scenario: SGR colors

- **WHEN** output contains `ESC[31mred ESC[1;4mbold-underline ESC[38;2;10;20;30mtruecolor`
- **THEN** each run is drawn with the specified color and attributes

#### Scenario: Default colors match the daemon

- **WHEN** the dark scheme is active and a program queries `OSC 11 ?`
- **THEN** the color the daemon reports equals the background the view draws

#### Scenario: Wide characters

- **WHEN** output contains `が` followed by `a`
- **THEN** `が` spans two cells and `a` is drawn in the third cell

#### Scenario: Low-contrast foreground

- **WHEN** text is drawn in a foreground color whose contrast ratio against its background is below 4.5
- **THEN** the drawn foreground is adjusted so the ratio is at least 4.5

### Requirement: Cursor

The terminal view SHALL draw the cursor at the terminal's cursor position using the shape the terminal requests (block, underline, or bar), SHALL hide it when the terminal hides it, and SHALL blink it while the view has keyboard focus. When the view does not have keyboard focus, the cursor SHALL be drawn as a non-blinking hollow block.

#### Scenario: Shape change

- **WHEN** output contains `ESC[6 q`
- **THEN** the cursor is drawn as a bar

#### Scenario: Unfocused

- **WHEN** the window loses focus
- **THEN** the cursor stops blinking and is drawn as a hollow block

### Requirement: Grid size follows the view

The terminal grid size SHALL be computed from the view size minus a 4-point inner padding, divided by the cell size derived from the font (advance width and line height, rounded to device pixels). After the view size stops changing for 50 ms, the terminal SHALL be resized and, when the session is live and the grid size changed, a `resize` frame SHALL be sent. The cell size SHALL be given to the terminal in device pixels. Moving the window between displays with different scale factors SHALL recompute the cell size.

#### Scenario: Window resize

- **WHEN** the user resizes the window and stops
- **THEN** within 100 ms a single `resize` frame with the new cols and rows is sent and `stty size` in the shell reports the same values

#### Scenario: Unchanged grid

- **WHEN** the view size changes by less than one cell
- **THEN** no `resize` frame is sent

#### Scenario: Display change

- **WHEN** the window moves from a Retina display to a non-Retina display
- **THEN** glyphs are re-rasterized for the new scale and the cell pixel size reported to the terminal changes accordingly

### Requirement: Incremental redraw

The terminal view SHALL redraw only rows that changed since the last frame, and SHALL not redraw at all when nothing changed apart from the cursor blink.

#### Scenario: Single line update

- **WHEN** one character is echoed on the prompt line
- **THEN** only that row (and the cursor) is redrawn
