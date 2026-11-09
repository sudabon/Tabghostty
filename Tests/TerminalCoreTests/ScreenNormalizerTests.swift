import Testing
@testable import TerminalCore

/// spec: engine-parity「Fixture screens match the daemon's ghostty screen model」の正規化（phase6 design D5）。
@Suite struct ScreenNormalizerTests {
    /// 正準等価で比べないように、Unicode のスカラー値の列で比べる。
    private func scalars(_ string: String) -> [UInt32] { string.unicodeScalars.map(\.value) }

    private func cell(_ text: String, _ width: CellWidth = .narrow) -> ScreenNormalizer.Cell {
        ScreenNormalizer.Cell(text: text, width: width)
    }

    // MARK: - セルの列から

    @Test func wideContinuationCellsAreSkipped() {
        let line = ScreenNormalizer.line([
            cell("日", .wide), cell("", .spacerTail), cell("本", .wide), cell("", .spacerTail), cell("a"),
        ])
        #expect(line == "日本a")
    }

    @Test func emptyCellsBecomeSpacesAndOnlyTrailingSpacesAreTrimmed() {
        let line = ScreenNormalizer.line([cell("a"), cell(""), cell("b"), cell(""), cell(" "), cell("")])
        #expect(line == "a b")
        #expect(ScreenNormalizer.line([cell(""), cell(""), cell("")]) == "")
        #expect(ScreenNormalizer.line([]) == "")
    }

    // Go の strings.TrimRight(s, " ") と同じく、U+0020 以外の空白は残す。
    @Test func otherWhitespaceAtTheEndIsKept() {
        #expect(scalars(ScreenNormalizer.line([cell("a"), cell("\u{3000}", .wide), cell("", .spacerTail), cell("")])) == [0x61, 0x3000])
        #expect(scalars(ScreenNormalizer.line([cell("a"), cell("\t"), cell("")])) == [0x61, 0x09])
    }

    @Test func combiningMarksStayWithTheirBaseCharacter() {
        // 書記素クラスタとして同じセルにある場合。
        #expect(scalars(ScreenNormalizer.line([cell("e\u{301}"), cell("x")])) == [0x65, 0x301, 0x78])
        // 結合文字だけのセルは、前の文字に付く（あいだに空白を入れない）。
        #expect(scalars(ScreenNormalizer.line([cell("e"), cell("\u{301}"), cell("")])) == [0x65, 0x301])
        // 結合文字の付いた空白は、行末の空白として削らない。
        #expect(scalars(ScreenNormalizer.line([cell("a"), cell(" \u{301}"), cell("")])) == [0x61, 0x20, 0x301])
    }

    @Test func spacerHeadCountsAsTrailingBlank() {
        #expect(ScreenNormalizer.line([cell("a"), cell("b"), cell("", .spacerHead)]) == "ab")
    }

    // MARK: - 端末から

    @Test func terminalLinesCoverTheVisibleRowsOnly() throws {
        let terminal = try VTTerminal(cols: 20, rows: 3, maxScrollback: 100)
        terminal.write(bytes("one\r\ntwo\r\nthree\r\nfour\r\nfive"))
        // スクロールバックに入った one と two は含めない。
        #expect(terminal.normalizedScreenLines() == ["three", "four", "five"])
    }

    @Test func japaneseWideCharactersAndTrailingSpaces() throws {
        let terminal = try VTTerminal(cols: 20, rows: 2, maxScrollback: 0)
        terminal.write(bytes("日本語 abc   \r\n  末尾  "))
        #expect(terminal.normalizedScreenLines() == ["日本語 abc", "  末尾"])
    }

    @Test func wideCharacterWrappedAtTheLastColumn() throws {
        let terminal = try VTTerminal(cols: 5, rows: 2, maxScrollback: 0)
        terminal.write(bytes("abcd日"))
        // 行末の 1 セルには入らないので、次の行へ折り返す（行末は spacer head）。
        #expect(terminal.normalizedScreenLines() == ["abcd", "日"])
    }

    @Test func combiningMarksInTheTerminal() throws {
        let terminal = try VTTerminal(cols: 10, rows: 2, maxScrollback: 0)
        terminal.write(bytes("e\u{301}x\r\nか\u{3099}き"))
        let lines = terminal.normalizedScreenLines()
        #expect(lines.map(scalars) == [[0x65, 0x301, 0x78], [0x304B, 0x3099, 0x304D]])
    }

    @Test func alternateScreenIsReadWhileActive() throws {
        let terminal = try VTTerminal(cols: 10, rows: 2, maxScrollback: 10)
        terminal.write(bytes("primary"))
        terminal.write(bytes("\u{1b}[?1049h\u{1b}[Halt"))
        #expect(terminal.normalizedScreenLines() == ["alt", ""])
        terminal.write(bytes("\u{1b}[?1049l"))
        #expect(terminal.normalizedScreenLines() == ["primary", ""])
    }

    // 描画用の RenderState の dirty を消費しない（描画中の端末で呼んでも、次のフレームが欠けない）。
    @Test func readingDoesNotConsumeRenderDirtyState() throws {
        let terminal = try VTTerminal(cols: 10, rows: 3, maxScrollback: 10)
        _ = try terminal.makeSnapshot(forceFull: true)
        terminal.write(bytes("\u{1b}[2;1Hchanged"))
        #expect(terminal.normalizedScreenLines() == ["", "changed", ""])
        let snapshot = try terminal.makeSnapshot()
        #expect(snapshot.dirtyRows.map(\.y).contains(1))
    }
}
