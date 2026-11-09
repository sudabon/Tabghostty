# Spec Delta

## Purpose

Defines how hyperlinks in terminal output are recognized and opened.

## ADDED Requirements

### Requirement: Link recognition

The terminal view SHALL recognize two kinds of links:

- OSC 8 hyperlinks attached to cells.
- Plain `http://` and `https://` URLs appearing in the displayed text, including URLs that wrap onto the next row.

Trailing punctuation that is commonly not part of a URL (`.`, `,`, `)`, `]`, `'`, `"`) SHALL be excluded when unbalanced.

#### Scenario: Plain URL

- **WHEN** output contains `See https://example.com/docs.`
- **THEN** `https://example.com/docs` is recognized as a link without the final period

#### Scenario: OSC 8

- **WHEN** output contains an OSC 8 hyperlink with text `docs` pointing to `https://example.com`
- **THEN** the cells showing `docs` are recognized as a link to `https://example.com`

### Requirement: Opening links

While the Command key is held and the pointer is over a link, the link's cells SHALL be underlined and the pointer SHALL become a pointing hand. Command-click SHALL open the link with the default application when its scheme is `http` or `https`. Links with other schemes SHALL NOT be opened. A plain click without Command SHALL NOT open links and SHALL keep its normal selection or mouse-reporting behavior.

#### Scenario: Command-click

- **WHEN** the user Command-clicks `https://example.com`
- **THEN** the default browser opens that URL

#### Scenario: Plain click

- **WHEN** the user clicks a URL without holding Command
- **THEN** no browser opens

#### Scenario: Unsafe scheme

- **WHEN** the user Command-clicks an OSC 8 link to `file:///Applications/Calculator.app`
- **THEN** nothing is opened
