import Foundation
import os
import Testing
@testable import TerminalCore

/// クリップボードへの書き込みを記録する。
final class RecordingClipboard: TerminalClipboard, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    var writes: [String] { state.withLock { $0 } }
    func write(_ text: String) { state.withLock { $0.append(text) } }
}

/// spec: terminal-clipboard（phase2）のうち、端末とコントローラで確かめられるもの。
@Suite struct TerminalClipboardTests {
    private let surface = MouseSurface.testSurface
    private static let second: UInt64 = 1_000_000_000

    private func liveController(_ sink: RecordingSink, cols: Int = 80, clipboard: (any TerminalClipboard)? = nil) async throws -> TerminalController {
        let controller = try TerminalController(sid: "s1", cols: cols, maxScrollback: 1000, colors: nil, sink: sink, clipboard: clipboard)
        await controller.setViewGrid(.init(cols: cols, rows: 24, cellWidthPx: 16, cellHeightPx: 34))
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()
        return controller
    }

    /// セル（0 始まり）の操作。`right` なら、セルの右端の近く（そのセルまで選ぶ）を指す。
    private func selection(_ kind: SelectionInput.Kind, column: Int, row: Int, right: Bool = false) -> SelectionInput {
        let center = surface.center(ofColumn: column, row: row)
        let x = right ? Double(surface.paddingLeft + (column + 1) * surface.cellWidth - 1) : center.x
        return SelectionInput(kind: kind, cell: GridPoint(x: column, y: row), x: x, y: center.y, surface: surface)
    }

    private func press(column: Int, row: Int, at time: UInt64) -> SelectionInput {
        selection(.press(timeNanoseconds: time, repeatIntervalNanoseconds: Self.second / 2, repeatDistance: 16), column: column, row: row)
    }

    @MainActor
    private func click(_ controller: TerminalController, column: Int, row: Int, at time: UInt64) {
        controller.enqueueSelection(press(column: column, row: row, at: time))
        controller.enqueueSelection(selection(.release, column: column, row: row))
    }

    // MARK: - Requirement: Text selection

    // Scenario: Drag selection
    @MainActor
    @Test func dragSelectsText() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes("hello world\r\nsecond line"))

        controller.enqueueSelection(press(column: 0, row: 0, at: 1 * Self.second))
        controller.enqueueSelection(selection(.drag, column: 4, row: 0, right: true))
        controller.enqueueSelection(selection(.release, column: 4, row: 0, right: true))
        #expect(await controller.selectionText() == "hello")

        // 2 行にまたがる。
        controller.enqueueSelection(press(column: 6, row: 0, at: 5 * Self.second))
        controller.enqueueSelection(selection(.drag, column: 5, row: 1, right: true))
        controller.enqueueSelection(selection(.release, column: 5, row: 1, right: true))
        #expect(await controller.selectionText() == "world\nsecond")

        // 選択した列は描画のスナップショットに入る。
        let snapshot = try #require(await controller.makeSnapshot(forceFull: true))
        #expect(snapshot.selections[0] == 6...79)
        #expect(snapshot.selections[1] == 0...5)
        #expect(snapshot.selections[2] == nil)
        // 選択は何も送らない。
        #expect(sink.inputFrames.isEmpty)
    }

    // Scenario: Word and line
    @MainActor
    @Test func doubleClickSelectsAWordAndTripleClickALine() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes("echo hello-world done\r\nnext"))

        let start = 10 * Self.second
        click(controller, column: 6, row: 0, at: start)
        click(controller, column: 6, row: 0, at: start + Self.second / 10)
        #expect(await controller.selectionText() == "hello-world")

        click(controller, column: 6, row: 0, at: start + Self.second / 5)
        #expect(await controller.selectionText() == "echo hello-world done")
    }

    // Clicking without dragging SHALL clear the selection.
    @MainActor
    @Test func clickWithoutDragClearsTheSelection() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes("hello world"))
        controller.enqueueSelection(press(column: 0, row: 0, at: Self.second))
        controller.enqueueSelection(selection(.drag, column: 4, row: 0, right: true))
        controller.enqueueSelection(selection(.release, column: 4, row: 0, right: true))
        #expect(await controller.selectionText() == "hello")

        click(controller, column: 8, row: 0, at: 5 * Self.second)
        #expect(await controller.selectionText() == "")
        #expect(await controller.withTerminal { $0.hasSelection } == false)
    }

    // コピーするテキスト: 2 セル幅の文字の空きセルを除き、ソフト折り返しを結合し、行末の空白を削る。
    @MainActor
    @Test func copiedTextIsPlain() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink, cols: 10)
        // 1 行目: 色付きの日本語と行末の空白。2〜3 行目: 10 列で折り返される 15 文字。
        await controller.receiveOutput(bytes("\u{1b}[31m日本語\u{1b}[0m   \r\nabcdefghijKLMNO"))

        controller.enqueueSelection(press(column: 0, row: 0, at: Self.second))
        controller.enqueueSelection(selection(.drag, column: 4, row: 2, right: true))
        controller.enqueueSelection(selection(.release, column: 4, row: 2, right: true))
        #expect(await controller.selectionText() == "日本語\nabcdefghijKLMNO")
    }

    // MARK: - Requirement: Paste with Command-V

    @Test func lineBreaksAreNormalized() {
        #expect(PasteText.normalizeLineBreaks("a\r\nb\nc\rd") == "a\rb\rc\rd")
        #expect(PasteText.normalizeLineBreaks("\n\n") == "\r\r")
        #expect(PasteText.normalizeLineBreaks("¥ ok") == "¥ ok")
    }

    @Test func pasteEncoding() {
        #expect(PasteText.encode("ls -la\r\npwd\n", bracketed: false) == bytes("ls -la\rpwd\r"))
        #expect(PasteText.encode("ls -la\npwd", bracketed: true) == bytes("\u{1b}[200~ls -la\rpwd\u{1b}[201~"))
        #expect(PasteText.encode("one line", bracketed: false) == bytes("one line"))
    }

    // 危険なペーストの判定（phase2 design D4）
    @Test func unsafePasteDetection() {
        // bracketed paste が無効なときの改行
        #expect(PasteText.isSafe("rm -rf build\nls", bracketed: false) == false)
        #expect(PasteText.isSafe("rm -rf build\r\n", bracketed: false) == false)
        #expect(PasteText.isSafe("echo ok", bracketed: false))
        #expect(PasteText.isSafe("", bracketed: false))
        #expect(PasteText.encode("", bracketed: false).isEmpty)
        // 有効なら改行は安全
        #expect(PasteText.isSafe("rm -rf build\nls", bracketed: true))
        // 終わりのシーケンスが混ざっている
        #expect(PasteText.isSafe("x\u{1b}[201~rm -rf /\n", bracketed: true) == false)
        #expect(PasteText.isSafe("x\u{1b}[201~", bracketed: false) == false)
    }

    // Scenario: Bracketed multi-line paste
    @Test func bracketedPasteWrapsTheText() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes("\u{1b}[?2004h"))
        #expect(await controller.paste("echo one\necho two") == .sent)
        #expect(sink.inputFrames == [bytes("\u{1b}[200~echo one\recho two\u{1b}[201~")])
    }

    // Scenario: Unsafe paste confirmation / Cancelled unsafe paste
    @Test func unsafePasteNeedsConfirmation() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        #expect(await controller.paste("rm -rf build\nls") == .needsConfirmation)
        #expect(sink.inputFrames.isEmpty)
        #expect(await controller.paste("rm -rf build\nls", allowUnsafe: true) == .sent)
        #expect(sink.inputFrames == [bytes("rm -rf build\rls")])

        // 1 行なら確認なしで送る。¥ はそのまま（Scenario: Pasted yen）。
        sink.removeAll()
        #expect(await controller.paste("echo ¥100") == .sent)
        #expect(sink.inputFrames == [bytes("echo ¥100")])
    }

    // Paste SHALL be ignored while the session is not live.
    @Test func pasteIsIgnoredUnlessLive() async throws {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", maxScrollback: 100, colors: nil, sink: sink)
        #expect(await controller.paste("hello") == .ignored)
        await controller.attach()
        #expect(await controller.paste("hello") == .ignored)
        #expect(sink.inputFrames.isEmpty)
    }

    // ペーストしたら最下部に戻る。
    @MainActor
    @Test func pasteReturnsToTheBottom() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes((0..<100).map { "line \($0)\r\n" }.joined()))
        controller.enqueueScroll(ScrollInput(lines: 20, x: 10, y: 10, surface: surface))
        await controller.flushInput()
        #expect(await controller.withTerminal { $0.isViewportAtBottom } == false)
        #expect(await controller.paste("x") == .sent)
        #expect(await controller.withTerminal { $0.isViewportAtBottom })
    }

    // MARK: - Requirement: OSC 52 clipboard access

    // Scenario: Remote copy
    @Test func liveClipboardWriteReachesThePasteboard() async throws {
        let sink = RecordingSink()
        let clipboard = RecordingClipboard()
        let controller = try await liveController(sink, clipboard: clipboard)
        await controller.receiveOutput(bytes("\u{1b}]52;c;\(Data("hello".utf8).base64EncodedString())\u{07}"))
        #expect(clipboard.writes == ["hello"])
        #expect(sink.inputFrames.isEmpty)
    }

    // Scenario: Replayed clipboard write
    @Test func replayedClipboardWriteIsDiscarded() async throws {
        let sink = RecordingSink()
        let clipboard = RecordingClipboard()
        let controller = try TerminalController(sid: "s1", maxScrollback: 100, colors: nil, sink: sink, clipboard: clipboard)
        await controller.attach()
        await controller.receiveReplay(bytes("\u{1b}]52;c;\(Data("old".utf8).base64EncodedString())\u{07}"), done: true)
        #expect(clipboard.writes.isEmpty)
    }

    // Scenario: Read refused
    @Test func clipboardReadIsNotAnswered() async throws {
        let sink = RecordingSink()
        let clipboard = RecordingClipboard()
        let controller = try await liveController(sink, clipboard: clipboard)
        await controller.receiveOutput(bytes("\u{1b}]52;c;?\u{07}"))
        #expect(sink.inputFrames.isEmpty)
        #expect(clipboard.writes.isEmpty)
    }
}
