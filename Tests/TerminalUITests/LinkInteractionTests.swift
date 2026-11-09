import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: terminal-links「Opening links」、phase5 design D6。
@MainActor
@Suite struct LinkInteractionTests {
    private struct Fixture {
        let view: TerminalView
        let controller: TerminalController
        let sink: RecordingSink
        let window: NSWindow
        let opened: Box
    }

    final class Box {
        var urls: [URL] = []
    }

    private func makeFixture(output: String, renderer: TerminalRendererKind = .coreText) async throws -> Fixture {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", cols: 60, rows: 4, maxScrollback: 10, colors: Palette.dark.terminalColors, sink: sink)
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark, renderer: renderer)
        let size = NSSize(width: 2 * GridGeometry.padding + 60 * view.metrics.width, height: 2 * GridGeometry.padding + 4 * view.metrics.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        await controller.setViewGrid(.init(cols: 60, rows: 4, cellWidthPx: view.metrics.widthPx, cellHeightPx: view.metrics.heightPx))
        await controller.attach()
        await controller.receiveReplay(Array(output.utf8), done: true)
        sink.removeAll()
        view.controller = controller
        view.apply(try #require(await controller.makeSnapshot(forceFull: true)))
        let opened = Box()
        view.linkOpener = { opened.urls.append($0) }
        return Fixture(view: view, controller: controller, sink: sink, window: window, opened: opened)
    }

    /// セル (x, y) の真ん中のウィンドウ座標。
    private func windowPoint(_ view: TerminalView, x: Int, y: Int) -> NSPoint {
        let rect = view.cellRect(x: x, y: y)
        return view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, _ view: TerminalView, x: Int, y: Int, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: windowPoint(view, x: x, y: y), modifierFlags: flags, timestamp: 1,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private static let text = "See https://example.com/docs. and \u{1b}]8;;https://example.com/osc\u{1b}\\docs\u{1b}]8;;\u{1b}\\ \u{1b}]8;;file:///Applications/Calculator.app\u{1b}\\calc\u{1b}]8;;\u{1b}\\"

    // Scenario: Command-click — 既定のブラウザで開く。
    @Test func commandClickOpensPlainURLs() async throws {
        let fixture = try await makeFixture(output: Self.text)
        fixture.view.mouseDown(with: mouse(.leftMouseDown, fixture.view, x: 10, y: 0, flags: .command))
        fixture.view.mouseUp(with: mouse(.leftMouseUp, fixture.view, x: 10, y: 0, flags: .command))
        #expect(fixture.opened.urls == [URL(string: "https://example.com/docs")!])
        // 選択は始めない。
        #expect(fixture.view.pointerGesture == .none)
    }

    @Test func commandClickOpensOSC8Links() async throws {
        let fixture = try await makeFixture(output: Self.text)
        fixture.view.mouseDown(with: mouse(.leftMouseDown, fixture.view, x: 35, y: 0, flags: .command))
        #expect(await waitUntil { !fixture.opened.urls.isEmpty })
        #expect(fixture.opened.urls == [URL(string: "https://example.com/osc")!])
    }

    // Scenario: Plain click — 修飾キー無しでは開かず、選択になる。
    @Test func plainClickDoesNotOpen() async throws {
        let fixture = try await makeFixture(output: Self.text)
        fixture.view.mouseDown(with: mouse(.leftMouseDown, fixture.view, x: 10, y: 0))
        #expect(fixture.view.pointerGesture == .select)
        fixture.view.mouseUp(with: mouse(.leftMouseUp, fixture.view, x: 10, y: 0))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.opened.urls.isEmpty)
    }

    // Scenario: Unsafe scheme — file: の OSC 8 は開かない。
    @Test func unsafeSchemesAreNotOpened() async throws {
        let fixture = try await makeFixture(output: Self.text)
        fixture.view.commandKeyIsDown = { true }
        fixture.view.mouseMoved(with: mouse(.mouseMoved, fixture.view, x: 40, y: 0, flags: .command))
        #expect(await waitUntil { fixture.view.hoveredLink?.url == "file:///Applications/Calculator.app" })
        fixture.view.mouseDown(with: mouse(.leftMouseDown, fixture.view, x: 40, y: 0, flags: .command))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.opened.urls.isEmpty)
    }

    // Command を押している間は、ポインタの下のリンクに下線を引く（Core Text と Metal で同じ）。離すと消す。
    @Test(arguments: TerminalRendererKind.allCases)
    func commandHoverUnderlinesTheLink(renderer: TerminalRendererKind) async throws {
        let fixture = try await makeFixture(output: Self.text, renderer: renderer)
        fixture.view.commandKeyIsDown = { true }
        fixture.view.mouseMoved(with: mouse(.mouseMoved, fixture.view, x: 6, y: 0, flags: .command))
        #expect(await waitUntil { fixture.view.hoveredLink != nil })
        let link = try #require(fixture.view.hoveredLink)
        #expect(link.url == "https://example.com/docs")
        #expect(link.spans == [LinkSpan(row: 0, columns: 4...27)])
        let underlines = fixture.view.hoveredLinkUnderlines()
        #expect(underlines.count == 24)
        #expect(underlines.allSatisfy { $0.rect.maxY <= fixture.view.rowRect(0).maxY })

        // 修飾キー無しで動かすと消える。
        fixture.view.mouseMoved(with: mouse(.mouseMoved, fixture.view, x: 6, y: 0))
        #expect(fixture.view.hoveredLink == nil)
        #expect(fixture.view.hoveredLinkUnderlines().isEmpty)
    }

    // 下線は、リンクのセルの文字の色で、Core Text と Metal で同じに描く。
    @Test func hoverUnderlineMatchesAcrossRenderers() async throws {
        let coreText = try await makeFixture(output: Self.text, renderer: .coreText)
        let metal = try await makeFixture(output: Self.text, renderer: .metal)
        for fixture in [coreText, metal] {
            fixture.view.commandKeyIsDown = { true }
            fixture.view.mouseMoved(with: mouse(.mouseMoved, fixture.view, x: 6, y: 0, flags: .command))
            #expect(await waitUntil { fixture.view.hoveredLink != nil })
        }
        #expect(coreText.view.hoveredLinkUnderlines() == metal.view.hoveredLinkUnderlines())
    }
}
