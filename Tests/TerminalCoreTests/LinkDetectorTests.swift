import Testing
@testable import TerminalCore

/// spec: terminal-links「Link recognition」「Opening links」、phase5 design D6。
@Suite struct LinkDetectorTests {
    private func urls(_ text: String) -> [String] {
        let characters = Array(text)
        return LinkDetector.urlRanges(in: characters).map { String(characters[$0]) }
    }

    // Scenario: Plain URL — 最後のピリオドは含めない。
    @Test func trailingPunctuationIsExcluded() {
        #expect(urls("See https://example.com/docs.") == ["https://example.com/docs"])
        #expect(urls("a https://example.com/x, b") == ["https://example.com/x"])
        #expect(urls("go to http://example.com/path?q=1; now") == ["http://example.com/path?q=1"])
        #expect(urls("really https://example.com!?") == ["https://example.com"])
        #expect(urls("https://example.com/a.b.c/") == ["https://example.com/a.b.c/"])
    }

    @Test func boundariesStopAtWhitespaceAndQuotes() {
        #expect(urls("<https://example.com/x>") == ["https://example.com/x"])
        #expect(urls("\"https://example.com/q\"") == ["https://example.com/q"])
        #expect(urls("'https://example.com/s'") == ["https://example.com/s"])
        #expect(urls("`https://example.com/t`") == ["https://example.com/t"])
        #expect(urls("two https://a.example http://b.example") == ["https://a.example", "http://b.example"])
        #expect(urls("HTTPS://EXAMPLE.COM/UP") == ["HTTPS://EXAMPLE.COM/UP"])
        // スキームの後に何も無い・英数字の直後・ほかのスキームは URL にしない。
        #expect(urls("https:// x") == [])
        #expect(urls("xhttps://example.com") == [])
        #expect(urls("ftp://example.com file:///etc/passwd") == [])
    }

    @Test func bracketsAreKeptOnlyWhenBalanced() {
        #expect(urls("https://en.wikipedia.org/wiki/Foo_(bar)") == ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        #expect(urls("(see https://example.com/x)") == ["https://example.com/x"])
        #expect(urls("(see https://en.wikipedia.org/wiki/Foo_(bar)).") == ["https://en.wikipedia.org/wiki/Foo_(bar)"])
        #expect(urls("[link](https://example.com/md)") == ["https://example.com/md"])
        #expect(urls("[https://example.com/arr[0]]") == ["https://example.com/arr[0]"])
    }

    @Test func onlyHTTPAndHTTPSAreOpenable() {
        #expect(LinkDetector.isOpenable("https://example.com"))
        #expect(LinkDetector.isOpenable("HTTP://example.com/x"))
        // Scenario: Unsafe scheme
        #expect(!LinkDetector.isOpenable("file:///Applications/Calculator.app"))
        #expect(!LinkDetector.isOpenable("javascript:alert(1)"))
        #expect(!LinkDetector.isOpenable("ssh://host"))
        #expect(!LinkDetector.isOpenable("https://"))
        #expect(!LinkDetector.isOpenable("not a url"))
    }

    // MARK: - セルから探す

    private func row(_ text: String, cols: Int) -> [CellSnapshot] {
        var cells: [CellSnapshot] = []
        for character in text {
            var cell = CellSnapshot.blank
            cell.text = String(character)
            cells.append(cell)
        }
        while cells.count < cols { cells.append(.blank) }
        return cells
    }

    @Test func plainLinkAtACell() throws {
        let rows = [row("See https://example.com/docs. ok", cols: 40)]
        let link = try #require(LinkDetector.plainLink(at: GridPoint(x: 10, y: 0), rows: rows, wrapped: [false]))
        #expect(link.url == "https://example.com/docs")
        #expect(link.kind == .plain)
        #expect(link.spans == [LinkSpan(row: 0, columns: 4...27)])
        #expect(link.contains(GridPoint(x: 4, y: 0)))
        #expect(!link.contains(GridPoint(x: 28, y: 0)))
        // URL の外のセル。
        #expect(LinkDetector.plainLink(at: GridPoint(x: 1, y: 0), rows: rows, wrapped: [false]) == nil)
        #expect(LinkDetector.plainLink(at: GridPoint(x: 28, y: 0), rows: rows, wrapped: [false]) == nil)
    }

    // 折り返した URL は、前後の行とつないで 1 つのリンクにする（どちらの行から指しても同じ）。
    @Test func wrappedURLsSpanRows() throws {
        let rows = [row("x https://example.c", cols: 19), row("om/long/path y", cols: 19), row("next line", cols: 19)]
        let wrapped = [true, false, false]
        let fromFirst = try #require(LinkDetector.plainLink(at: GridPoint(x: 5, y: 0), rows: rows, wrapped: wrapped))
        let fromSecond = try #require(LinkDetector.plainLink(at: GridPoint(x: 3, y: 1), rows: rows, wrapped: wrapped))
        #expect(fromFirst == fromSecond)
        #expect(fromFirst.url == "https://example.com/long/path")
        #expect(fromFirst.spans == [LinkSpan(row: 0, columns: 2...18), LinkSpan(row: 1, columns: 0...11)])
        // 折り返していなければ、つながない。
        let unwrapped = try #require(LinkDetector.plainLink(at: GridPoint(x: 5, y: 0), rows: rows, wrapped: [false, false, false]))
        #expect(unwrapped.url == "https://example.c")
    }

    // MARK: - OSC 8（端末から読む）

    // Scenario: OSC 8 — `docs` のセルが https://example.com へのリンクになる。
    @Test func osc8LinksAreReadFromCells() throws {
        let terminal = try VTTerminal(cols: 40, rows: 3, maxScrollback: 0)
        terminal.write(bytes("read \u{1b}]8;;https://example.com\u{1b}\\docs\u{1b}]8;;\u{1b}\\ now"))
        #expect(terminal.hyperlinkURI(x: 5, y: 0) == "https://example.com")
        #expect(terminal.hyperlinkURI(x: 4, y: 0) == nil)
        let link = try #require(terminal.hyperlink(at: GridPoint(x: 7, y: 0)))
        #expect(link == TerminalLink(url: "https://example.com", kind: .hyperlink, spans: [LinkSpan(row: 0, columns: 5...8)]))
        #expect(terminal.hyperlink(at: GridPoint(x: 10, y: 0)) == nil)
    }

    @Test func osc8LinksFollowSoftWraps() throws {
        let terminal = try VTTerminal(cols: 10, rows: 3, maxScrollback: 0)
        terminal.write(bytes("12345\u{1b}]8;;https://example.com/w\u{1b}\\abcdefgh\u{1b}]8;;\u{1b}\\!"))
        #expect(terminal.viewportRowWraps(0))
        let link = try #require(terminal.hyperlink(at: GridPoint(x: 1, y: 1)))
        #expect(link.spans == [LinkSpan(row: 0, columns: 5...9), LinkSpan(row: 1, columns: 0...2)])
    }

    // Scenario: Unsafe scheme — file: の OSC 8 は認識するが、開いてよいリンクではない。
    @Test func osc8WithAnUnsafeSchemeIsNotOpenable() throws {
        let terminal = try VTTerminal(cols: 40, rows: 2, maxScrollback: 0)
        terminal.write(bytes("\u{1b}]8;;file:///Applications/Calculator.app\u{1b}\\calc\u{1b}]8;;\u{1b}\\"))
        let link = try #require(terminal.hyperlink(at: GridPoint(x: 0, y: 0)))
        #expect(link.url == "file:///Applications/Calculator.app")
        #expect(!link.isOpenable)
    }

    @Test func snapshotReportsWrappedRows() async throws {
        let controller = try TerminalController(sid: "s1", cols: 10, rows: 3, maxScrollback: 0, colors: nil, sink: RecordingSink())
        await controller.attach()
        await controller.receiveReplay(bytes("0123456789abc\r\nshort"), done: true)
        let snapshot = try #require(await controller.makeSnapshot(forceFull: true))
        #expect(snapshot.wrappedRows == [0])
    }
}
