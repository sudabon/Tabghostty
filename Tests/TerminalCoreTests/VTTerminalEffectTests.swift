import Testing
@testable import TerminalCore

/// spec: terminal-engine（phase1-single-tab-terminal）の effect・リサイズ・スクロールバック。
@Suite struct VTTerminalEffectTests {
    // Requirement: Engine responses are delivered after the write completes — Scenario: DA1 reply
    @Test func primaryDeviceAttributesReplyIsQueued() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 1000)
        terminal.write(bytes("\u{1b}[c"))

        let effects = terminal.takeEffects()
        #expect(effects == [.ptyWrite(bytes("\u{1b}[?62;22c"))])
        // 取り出したら空になる。
        #expect(terminal.takeEffects().isEmpty)
    }

    // Requirement: Engine responses are delivered after the write completes — Scenario: Several queries in one write
    @Test func severalQueriesAreQueuedInOrder() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 1000)
        terminal.write(bytes("hello\u{1b}[c\u{1b}[6n"))

        let effects = terminal.takeEffects()
        #expect(effects.count == 2)
        #expect(effects.first == .ptyWrite(bytes("\u{1b}[?62;22c")))
        // DSR（CPR）: カーソルは 1 行目の 6 列目。
        #expect(effects.last == .ptyWrite(bytes("\u{1b}[1;6R")))
    }

    @Test func bellTitleAndNotificationAreQueued() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 1000)
        terminal.write(bytes("\u{07}\u{1b}]2;title\u{07}\u{1b}]9;done\u{07}"))

        #expect(terminal.takeEffects() == [.bell, .titleChanged, .desktopNotification(title: "", body: "done")])
    }

    // Requirement: Resize with cell pixel size — Scenario: Retina cell size report
    @Test func cellSizeReportUsesDevicePixels() throws {
        let terminal = try VTTerminal(cols: 100, rows: 30, maxScrollback: 1000)
        try terminal.resize(cols: 80, rows: 24, cellWidthPx: 16, cellHeightPx: 34)
        #expect(terminal.takeEffects().isEmpty)

        terminal.write(bytes("\u{1b}[16t"))
        // CSI 6 ; height ; width t
        #expect(terminal.takeEffects() == [.ptyWrite(bytes("\u{1b}[6;34;16t"))])

        terminal.write(bytes("\u{1b}[14t"))
        // CSI 4 ; height ; width t（テキスト領域のピクセルサイズ）
        #expect(terminal.takeEffects() == [.ptyWrite(bytes("\u{1b}[4;\(24 * 34);\(80 * 16)t"))])

        terminal.write(bytes("\u{1b}[18t"))
        #expect(terminal.takeEffects() == [.ptyWrite(bytes("\u{1b}[8;24;80t"))])
        #expect(terminal.cols == 80)
        #expect(terminal.rows == 24)
    }

    // Requirement: Configurable scrollback limit — Scenario: Limit enforced
    @Test func scrollbackIsLimited() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 100)
        for line in 0..<500 {
            terminal.write(bytes("line \(line)\r\n"))
        }
        #expect(terminal.scrollbackRows <= 100)
        #expect(terminal.scrollbackRows == 100)
        // 画面の最後には最新の行が残る。
        #expect(try terminal.plainText().contains("line 499"))
    }

    @Test func resetClearsScreenAndKeepsSize() throws {
        let terminal = try VTTerminal(cols: 40, rows: 10, maxScrollback: 100)
        terminal.write(bytes("hello\r\nworld"))
        terminal.reset()
        #expect(try terminal.plainText() == "")
        #expect(terminal.cols == 40)
        #expect(terminal.rows == 10)
    }

    // libghostty はページ単位でしか削除しないので、内部には上限より多くの行が残る（2026-11-09 の計測で 477 行）。
    // 利用者に見せる行数（`scrollbackRows`）は上限で丸める。
    @Test func rawScrollbackMayExceedConfiguredLimit() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 100)
        for line in 0..<500 {
            terminal.write(bytes("line \(line)\r\n"))
        }
        #expect(terminal.rawScrollbackRows >= terminal.scrollbackRows)
    }

    // 既定の配色は reset の後も残る（README の対応表の記述を確かめる）。
    @Test func defaultColorsSurviveReset() throws {
        let terminal = try VTTerminal(cols: 10, rows: 2, maxScrollback: 10)
        var palette = (0..<256).map { ColorRGB(r: UInt8($0), g: 0, b: 0) }
        palette[1] = ColorRGB(hex: 0xcc0000)
        try terminal.setColors(TerminalColorConfiguration(
            foreground: ColorRGB(hex: 0xcccccc), background: ColorRGB(hex: 0x1e1e1e), cursor: ColorRGB(hex: 0xffffff), palette: palette
        ))
        terminal.reset()
        terminal.write(bytes("\u{1b}[31mx"))
        let snapshot = try terminal.makeSnapshot(forceFull: true)
        #expect(snapshot.colors.background == ColorRGB(hex: 0x1e1e1e))
        #expect(snapshot.colors.foreground == ColorRGB(hex: 0xcccccc))
        #expect(snapshot.dirtyRows.first { $0.y == 0 }?.cells.first?.foreground == ColorRGB(hex: 0xcc0000))
    }
}
