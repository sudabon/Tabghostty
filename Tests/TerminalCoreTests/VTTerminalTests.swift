import Testing
@testable import TerminalCore

/// spec: terminal-engine（phase0-libghostty-foundation）の各シナリオ。
@Suite struct VTTerminalTests {
    private func makeTerminal() throws -> VTTerminal {
        try VTTerminal(cols: 80, rows: 24, maxScrollback: 10_000)
    }

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    // Requirement: Byte stream to terminal state — Scenario: Styled text
    @Test func styledTextBecomesPlainLines() throws {
        let terminal = try makeTerminal()
        terminal.write(bytes("Hello\r\n\u{1b}[31mRed\u{1b}[0m"))
        #expect(try terminal.plainText() == "Hello\nRed")
    }

    // Requirement: Byte stream to terminal state — Scenario: Escape sequence split across writes
    @Test func escapeSequenceSplitAcrossWrites() throws {
        let whole = try makeTerminal()
        whole.write(bytes("Hello\r\n\u{1b}[31mRed\u{1b}[0m"))

        let split = try makeTerminal()
        split.write(bytes("Hello\r\n\u{1b}[3"))
        split.write(bytes("1mRed\u{1b}[0m"))

        #expect(try split.plainText() == whole.plainText())
        #expect(try split.plainText() == "Hello\nRed")
    }

    // Requirement: Byte stream to terminal state — Scenario: UTF-8 character split across writes
    @Test func utf8CharacterSplitAcrossWrites() throws {
        let encoded = bytes("が")
        #expect(encoded.count == 3)

        let terminal = try makeTerminal()
        terminal.write(encoded[0..<2])
        terminal.write(encoded[2...])

        let text = try terminal.plainText()
        #expect(text == "が")
        #expect(!text.unicodeScalars.contains("\u{FFFD}"))
    }

    // Requirement: Plain-text extraction — Scenario: Styling is dropped
    @Test func stylingIsDropped() throws {
        let terminal = try makeTerminal()
        terminal.write(bytes("\u{1b}[1;32mbold green\u{1b}[0m plain \u{1b}[38;2;10;20;30mtruecolor\u{1b}[0m"))

        let text = try terminal.plainText()
        #expect(text == "bold green plain truecolor")
        #expect(!text.utf8.contains(0x1b))
    }

    // 1 行が 1 つの端末行に対応し、行末の空白が削られること。
    @Test func oneLinePerRowWithTrailingBlanksTrimmed() throws {
        let terminal = try makeTerminal()
        terminal.write(bytes("a   \r\n\r\nb"))
        #expect(try terminal.plainText() == "a\n\nb")
    }

    @Test func emptyTerminalHasNoText() throws {
        let terminal = try makeTerminal()
        #expect(try terminal.plainText() == "")
    }
}
