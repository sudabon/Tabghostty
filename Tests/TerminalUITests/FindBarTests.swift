import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: terminal-search「Find bar」「Search scope and matching」「Match navigation」、phase5 design D5。
@MainActor
@Suite struct FindBarTests {
    private struct Fixture {
        let view: TerminalView
        let controller: TerminalController
        let sink: RecordingSink
        let window: NSWindow
    }

    private func makeFixture(output: String, renderer: TerminalRendererKind = .coreText) async throws -> Fixture {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", cols: 60, rows: 6, maxScrollback: 1000, colors: Palette.dark.terminalColors, sink: sink)
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark, renderer: renderer)
        let size = NSSize(width: 2 * GridGeometry.padding + 60 * view.metrics.width, height: 2 * GridGeometry.padding + 6 * view.metrics.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        await controller.setViewGrid(.init(cols: 60, rows: 6, cellWidthPx: view.metrics.widthPx, cellHeightPx: view.metrics.heightPx))
        await controller.attach()
        await controller.receiveReplay(Array(output.utf8), done: true)
        sink.removeAll()
        view.controller = controller
        view.apply(try #require(await controller.makeSnapshot(forceFull: true)))
        window.makeFirstResponder(view)
        return Fixture(view: view, controller: controller, sink: sink, window: window)
    }

    private static let sample = (0..<40).map { $0 % 4 == 0 ? "ERROR at line \($0)" : "ok line \($0)" }.joined(separator: "\r\n")

    private func key(_ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// 入力欄に文字を打つ（フィールドエディタにキーを送る）。
    private func type(_ text: String, in fixture: Fixture) {
        for character in text {
            fixture.window.sendEvent(key(String(character), keyCode: 0, window: fixture.window))
        }
    }

    // Scenario: Open and close — Command-F で開き、打った文字はセッションに送らず、Escape で閉じて端末に戻る。
    @Test func openTypeAndCloseSendsNothingToTheSession() async throws {
        let fixture = try await makeFixture(output: Self.sample)
        fixture.view.showFindBar(nil)
        #expect(fixture.view.isFindBarVisible)
        #expect(fixture.view.findBarForTesting.hasFocus)

        type("error", in: fixture)
        #expect(fixture.view.findBarForTesting.query == "error")
        #expect(await waitUntil { fixture.view.findBarForTesting.status.total == 10 })
        #expect(fixture.view.findBarForTesting.countLabel.stringValue == "1 / 10")

        fixture.window.sendEvent(key("\u{1b}", keyCode: 0x35, window: fixture.window))
        #expect(!fixture.view.isFindBarVisible)
        #expect(fixture.window.firstResponder === fixture.view)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.sink.inputBytes.isEmpty)
        // 閉じると強調を消す。
        #expect(await waitUntil { await fixture.controller.searchStatus == .empty })
    }

    // Enter / Command-G で次、Shift+Enter / Command-Shift-G で前。端で反対側に戻る。
    @Test func enterAndCommandGNavigate() async throws {
        let fixture = try await makeFixture(output: Self.sample)
        fixture.view.showFindBar(nil)
        type("ERROR", in: fixture)
        #expect(await waitUntil { fixture.view.findBarForTesting.status.label == "1 / 10" })

        fixture.window.sendEvent(key("\r", keyCode: 0x24, window: fixture.window))
        #expect(await waitUntil { fixture.view.findBarForTesting.status.label == "2 / 10" })
        fixture.view.findNext(nil)
        #expect(await waitUntil { fixture.view.findBarForTesting.status.label == "3 / 10" })
        // Shift はアプリの今のイベントから読む（テストのイベントはアプリのイベントループを通らないので、差し替える）。
        fixture.view.findBarForTesting.currentModifierFlags = { .shift }
        fixture.window.sendEvent(key("\r", keyCode: 0x24, flags: .shift, window: fixture.window))
        fixture.view.findBarForTesting.currentModifierFlags = { [] }
        #expect(await waitUntil { fixture.view.findBarForTesting.status.label == "2 / 10" })
        fixture.view.findPrevious(nil)
        fixture.view.findPrevious(nil)
        #expect(await waitUntil { fixture.view.findBarForTesting.status.label == "10 / 10" })
        #expect(fixture.sink.inputBytes.isEmpty)
    }

    @Test func noMatchShowsZeroOfZero() async throws {
        let fixture = try await makeFixture(output: Self.sample)
        fixture.view.showFindBar(nil)
        type("nothing", in: fixture)
        #expect(await waitUntil { await fixture.controller.searchStatus.query == "nothing" })
        #expect(fixture.view.findBarForTesting.countLabel.stringValue == "0 / 0")
    }

    // 一致を強調し、今の一致は別の色で描く（Core Text と Metal で同じ色）。
    @Test(arguments: TerminalRendererKind.allCases)
    func matchesAreHighlighted(renderer: TerminalRendererKind) async throws {
        let fixture = try await makeFixture(output: "foo bar foo\r\nbaz foo", renderer: renderer)
        let status = await fixture.controller.search("foo")
        #expect(status.total == 3)
        fixture.view.apply(try #require(await fixture.controller.makeSnapshot()))
        #expect(fixture.view.searchHighlightKind(x: 0, y: 0) == .current)
        #expect(fixture.view.searchHighlightKind(x: 8, y: 0) == .match)
        #expect(fixture.view.searchHighlightKind(x: 4, y: 0) == nil)
        #expect(fixture.view.searchHighlightKind(x: 5, y: 1) == .match)
        let current = fixture.view.rowCellColors(CellSnapshot.blank, x: 1, y: 0)
        #expect(current.background == Palette.dark.searchCurrentMatch)
        let other = fixture.view.rowCellColors(CellSnapshot.blank, x: 9, y: 0)
        #expect(other.background == Palette.dark.searchMatch)
        #expect(ContrastAdjuster.contrastRatio(other.foreground, other.background) >= ContrastAdjuster.minimumRatio)
    }

    @Test func switchingSessionsSearchesTheNewSession() async throws {
        let fixture = try await makeFixture(output: Self.sample)
        fixture.view.showFindBar(nil)
        type("ERROR", in: fixture)
        #expect(await waitUntil { fixture.view.findBarForTesting.status.total == 10 })

        let other = try TerminalController(sid: "s2", cols: 60, rows: 6, maxScrollback: 100, colors: nil, sink: RecordingSink())
        await other.attach()
        await other.receiveReplay(Array("one ERROR only".utf8), done: true)
        fixture.view.controller = other
        #expect(await waitUntil { fixture.view.findBarForTesting.status.total == 1 })
        #expect(await waitUntil { await fixture.controller.searchStatus == .empty })
    }
}
