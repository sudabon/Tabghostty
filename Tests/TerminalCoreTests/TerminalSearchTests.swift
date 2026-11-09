import os
import Testing
@testable import TerminalCore

/// spec: terminal-search「Search scope and matching」「Match navigation」、phase5 design D5。
@Suite struct TerminalSearchTests {
    private func lines(_ count: Int, _ make: (Int) -> String) -> [UInt8] {
        bytes((0..<count).map(make).joined(separator: "\r\n"))
    }

    @Test func caseInsensitiveAndCoversScrollback() throws {
        let terminal = try VTTerminal(cols: 40, rows: 5, maxScrollback: 1000)
        // 30 行のうち、3 の倍数の行に ERROR / error / Error がある（10 行。最後の 2 つは画面にある）。
        terminal.write(lines(30) { index in
            index % 3 == 0 ? "line \(index) " + ["ERROR", "error", "Error"][(index / 3) % 3] + " here" : "line \(index) ok"
        })
        #expect(terminal.scrollbackRows == 25)
        let matches = try terminal.search("error")
        #expect(matches.count == 10)
        // 上（古い行）から順。行は画面の座標（スクロールバックの先頭が 0）。
        #expect(matches.map(\.startRow) == Array(stride(from: 0, to: 30, by: 3)))
        // 画面（25〜29 行目）にあるのは 27 行目の 1 つ。
        #expect(matches.filter { $0.startRow >= 25 }.count == 1)
        // 列の範囲（両端を含む）。"line 0 " の後ろの 5 文字。
        #expect(matches[0] == SearchMatch(startRow: 0, startColumn: 7, endRow: 0, endColumn: 11))
        #expect(matches[9].startColumn == 8)
        #expect(try terminal.search("ERROR").count == 10)
        #expect(try terminal.search("nothing").isEmpty)
    }

    /// viewport の行のテキスト。
    private func viewportText(_ terminal: VTTerminal) throws -> [String] {
        try terminal.makeSnapshot(forceFull: true).dirtyRows.map { $0.cells.map(\.text).joined() }
    }

    @Test func screenRowsMatchViewportOffsets() throws {
        let terminal = try VTTerminal(cols: 40, rows: 5, maxScrollback: 1000)
        terminal.write(lines(30) { "row \($0)" })
        let match = try #require(try terminal.search("row 7").first)
        #expect(match.startRow == 7)
        // 一致を見えるところに動かすと、viewport の行 = 画面の行 - viewportOffset。
        #expect(terminal.scrollToShow(match))
        let row = match.startRow - terminal.viewportOffset
        #expect((0..<5).contains(row))
        #expect(try viewportText(terminal)[row] == "row 7")
        // もう見えていれば動かさない。
        #expect(!terminal.scrollToShow(match))
    }

    // 最新の `scrollback_lines` 行より古い行は対象にしない（libghostty の内部に残っていても）。
    @Test func linesOlderThanTheScrollbackLimitAreExcluded() throws {
        let terminal = try VTTerminal(cols: 80, rows: 5, maxScrollback: 100)
        terminal.write(lines(500) { "needle \($0)" })
        // ページ単位で消すので、内部には上限より多くの行が残っている（phase1 design D2）。
        #expect(terminal.rawScrollbackRows > 100)
        let matches = try terminal.search("needle")
        #expect(matches.count == 105)
        #expect(matches.first?.startRow == terminal.minimumViewportOffset)
        let oldest = try #require(matches.first)
        // 見せてよいいちばん古い行が、最初の一致。
        #expect(terminal.scrollToShow(oldest))
        #expect(terminal.viewportOffset == terminal.minimumViewportOffset)
        #expect(try viewportText(terminal).first == "needle 395")
    }

    @Test func wrappedMatchesSpanRows() throws {
        let terminal = try VTTerminal(cols: 10, rows: 4, maxScrollback: 10)
        terminal.write(bytes("12345678abcdef"))
        let match = try #require(try terminal.search("78abc").first)
        // 1 行目は "12345678ab"、2 行目は "cdef"。
        #expect(match == SearchMatch(startRow: 0, startColumn: 6, endRow: 1, endColumn: 0))
    }

    // MARK: - TerminalController

    private func controller(_ text: [UInt8], rows: Int = 5) async throws -> TerminalController {
        let controller = try TerminalController(sid: "s1", cols: 40, rows: rows, maxScrollback: 1000, colors: nil, sink: RecordingSink())
        await controller.attach()
        await controller.receiveReplay(text, done: true)
        return controller
    }

    // Scenario: Matches in scrollback — `1 / 12` を出し、最初の一致まで viewport を動かす。
    @Test func firstMatchIsSelectedAndScrolledIntoView() async throws {
        let controller = try await controller(lines(60) { $0 % 5 == 0 ? "ERROR \($0)" : "fine \($0)" })
        let status = await controller.search("error")
        #expect(status == SearchStatus(query: "error", total: 12, current: 0))
        #expect(status.label == "1 / 12")
        let snapshot = try #require(await controller.makeSnapshot())
        // いちばん上の一致（0 行目）が見えていて、今の一致として強調される。
        let highlighted = snapshot.searchHighlights.filter { $0.value.contains { $0.isCurrent } }
        #expect(highlighted.count == 1)
        let row = try #require(highlighted.keys.first)
        #expect(snapshot.dirtyRows.first { $0.y == row }?.cells.map(\.text).joined().hasPrefix("ERROR 0") == true)
        #expect(highlighted[row]?.first?.columns == 0...4)
    }

    // Scenario: No match — `0 / 0`、viewport は動かない。
    @Test func noMatchDoesNotMoveTheViewport() async throws {
        let controller = try await controller(lines(60) { "line \($0)" })
        let before = await controller.withTerminal { $0.viewportOffset }
        let status = await controller.search("zzz")
        #expect(status.label == "0 / 0")
        #expect(await controller.withTerminal { $0.viewportOffset } == before)
        #expect(await controller.makeSnapshot()?.searchHighlights.isEmpty == true)
    }

    // Scenario: Wrap — 最後の一致の次は最初の一致。前へは逆。
    @Test func navigationWrapsAround() async throws {
        let controller = try await controller(lines(20) { $0 % 4 == 0 ? "hit \($0)" : "miss \($0)" })
        #expect(await controller.search("hit").total == 5)
        #expect(await controller.searchNext().current == 1)
        #expect(await controller.searchNext().current == 2)
        #expect(await controller.searchNext().current == 3)
        #expect(await controller.searchNext().current == 4)
        #expect(await controller.searchNext().current == 0)
        #expect(await controller.searchPrevious().current == 4)
        #expect(await controller.searchPrevious().current == 3)
        #expect(await controller.currentSearchMatch?.startRow == 12)
    }

    // 新しい出力が来たら、200 ms 後に検索し直して件数を知らせる。今の一致はそのまま。
    @Test func newOutputIsSearchedAgain() async throws {
        let controller = try await controller(bytes("found\r\n"))
        #expect(await controller.search("found").total == 1)
        let received = OSAllocatedUnfairLock(initialState: [SearchStatus]())
        controller.setSearchObserver { status in received.withLock { $0.append(status) } }
        await controller.receiveOutput(bytes("found again\r\nfound\r\n"))
        #expect(received.withLock { $0 }.isEmpty)
        try await Task.sleep(for: TerminalController.researchDelay + .milliseconds(150))
        #expect(received.withLock { $0 }.last == SearchStatus(query: "found", total: 3, current: 0))
    }

    @Test func endingTheSearchClearsTheHighlights() async throws {
        let controller = try await controller(bytes("abc abc"))
        #expect(await controller.search("abc").total == 2)
        #expect(await controller.makeSnapshot()?.searchHighlights[0]?.count == 2)
        await controller.endSearch()
        #expect(await controller.searchStatus == .empty)
        #expect(await controller.makeSnapshot()?.searchHighlights.isEmpty == true)
    }
}
