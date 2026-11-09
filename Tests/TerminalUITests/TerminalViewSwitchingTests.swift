import AppKit
import Testing
@testable import TerminalCore
@testable import TerminalUI

/// phase3: 1 つの `TerminalView` で表示するセッションを切り替える（design D1）と、キー入力の段階 0（design D4）。
@MainActor
@Suite struct TerminalViewSwitchingTests {
    private struct Fixture {
        let view: TerminalView
        let window: NSWindow
        let first: TerminalController
        let second: TerminalController
        let sink: RecordingSink
    }

    private func liveController(_ sid: String, sink: RecordingSink, view: TerminalView, output: String) async throws -> TerminalController {
        let controller = try TerminalController(sid: sid, cols: 40, rows: 6, maxScrollback: 100, colors: nil, sink: sink)
        await controller.setViewGrid(.init(cols: 40, rows: 6, cellWidthPx: view.metrics.widthPx, cellHeightPx: view.metrics.heightPx))
        await controller.attach()
        await controller.receiveReplay(Array(output.utf8), done: true)
        return controller
    }

    private func makeFixture() async throws -> Fixture {
        let sink = RecordingSink()
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark)
        let size = NSSize(
            width: 2 * GridGeometry.padding + 40 * view.metrics.width,
            height: 2 * GridGeometry.padding + 6 * view.metrics.height
        )
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        let first = try await liveController("s1", sink: sink, view: view, output: "first")
        let second = try await liveController("s2", sink: sink, view: view, output: "second")
        sink.removeAll()
        view.controller = first
        return Fixture(view: view, window: window, first: first, second: second, sink: sink)
    }

    private func key(_ characters: String, keyCode: UInt16, ignoring: String? = nil, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode
        )!
    }

    private func sentInput(_ sink: RecordingSink) async throws -> [UInt8] {
        try await Task.sleep(for: .milliseconds(40))
        return Array(sink.inputBytes.joined())
    }

    /// 入力が届くまで待ってから読む（Thread Sanitizer 付きでは遅くなる）。
    private func waitForInput(_ sink: RecordingSink, count: Int) async throws -> [UInt8] {
        for _ in 0..<400 where Array(sink.inputBytes.joined()).count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try await sentInput(sink)
    }

    private let noRange = NSRange(location: NSNotFound, length: 0)

    // MARK: - 未確定の文字列はコントローラに預ける（tasks 1.2）

    @Test func compositionStaysWithItsSessionAcrossSwitches() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: noRange)
        #expect(view.hasMarkedText())

        // 別のタブに切り替えると、未確定の文字列は表示されない（前のタブに預ける）。
        view.controller = fixture.second
        #expect(!view.hasMarkedText())
        #expect(view.markedText == "")

        // 戻ると、預けた文字列が戻る。
        view.controller = fixture.first
        #expect(view.hasMarkedText())
        #expect(view.markedText == "にほん")
        #expect(view.selectedRange() == NSRange(location: 3, length: 0))
        #expect(try await sentInput(fixture.sink).isEmpty)

        // Enter で確定して、そのタブにだけ送る（改行は送らない）。
        view.keyDown(with: key("\r", keyCode: 0x24))
        #expect(!view.hasMarkedText())
        #expect(try await waitForInput(fixture.sink, count: Array("にほん".utf8).count) == Array("にほん".utf8))
        #expect(fixture.sink.inputSIDs == ["s1"])
    }

    @Test func restoredCompositionCanBeCancelledOrEdited() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: noRange)
        view.controller = fixture.second
        view.controller = fixture.first

        // Backspace で 1 文字消す。
        view.keyDown(with: key("\u{7f}", keyCode: 0x33))
        #expect(view.markedText == "か")
        // Escape で取り消す（何も送らない）。
        view.keyDown(with: key("\u{1b}", keyCode: 0x35))
        #expect(!view.hasMarkedText())
        #expect(try await sentInput(fixture.sink).isEmpty)
    }

    @Test func restoredCompositionIsCommittedBeforeTheNextKey() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        view.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: noRange)
        view.controller = fixture.second
        view.controller = fixture.first

        // ほかのキーは、確定した文字列を送ってから、ふつうに処理する（Ctrl+C）。
        view.keyDown(with: key("\u{03}", keyCode: 0x08, ignoring: "c", flags: .control))
        #expect(try await waitForInput(fixture.sink, count: Array("あ".utf8).count + 1) == Array("あ".utf8) + [0x03])
    }

    @Test func switchingDoesNotResetTheSessions() async throws {
        let fixture = try await makeFixture()
        fixture.view.controller = fixture.second
        fixture.view.controller = fixture.first
        // 端末はリセットしない（replay も attach もしない）。
        #expect(await fixture.first.plainText() == "first")
        #expect(await fixture.second.plainText() == "second")
        #expect(await fixture.first.phase == .live)
        #expect(fixture.sink.allFrames.isEmpty)
    }

    // MARK: - 段階 0: コード（tasks 6.2 の一部。ChordController との組み合わせは ShellTests）

    @Test func keysConsumedByTheChordHandlerAreNotSentEvenOnRelease() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        var seen: [String] = []
        view.keyChordHandler = { stroke in
            seen.append(stroke.charactersIgnoringModifiers ?? "")
            return stroke.modifiers.contains(.control) && stroke.charactersIgnoringModifiers == "j"
        }
        // kitty keyboard protocol で、離したことも報告させる（フラグ 2）。
        await fixture.first.setTerminalModeForTesting(Array("\u{1b}[>2u".utf8))

        view.keyDown(with: key("\n", keyCode: 0x26, ignoring: "j", flags: .control))
        view.keyUp(with: key("\n", keyCode: 0x26, ignoring: "j", flags: .control, type: .keyUp))
        #expect(try await sentInput(fixture.sink).isEmpty)

        // 消費しなかったキーは、ふつうに送る。
        view.keyDown(with: key("x", keyCode: 0x07))
        #expect(try await waitForInput(fixture.sink, count: 1) == Array("x".utf8))
        #expect(seen == ["j", "x"])
    }
}

