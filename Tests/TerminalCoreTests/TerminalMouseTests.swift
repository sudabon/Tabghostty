import Testing
@testable import TerminalCore

/// spec: terminal-mouse（phase2）。
@Suite struct TerminalMouseTests {
    private let surface = MouseSurface.testSurface

    private func terminal() throws -> VTTerminal {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 1000)
        try terminal.resize(cols: 80, rows: 24, cellWidthPx: 16, cellHeightPx: 34)
        return terminal
    }

    private func mouse(_ action: MouseInput.Action, _ button: MouseInput.Button?, column: Int, row: Int, pressed: Bool = false) -> MouseInput {
        let point = surface.center(ofColumn: column, row: row)
        return MouseInput(action: action, button: button, x: point.x, y: point.y, anyButtonPressed: pressed, surface: surface)
    }

    // MARK: - Requirement: Mouse reporting

    // Scenario: SGR encoding — 10 列目・5 行目（1 始まり）をクリックする。
    @Test func sgrClickReportsCellCoordinates() throws {
        let terminal = try terminal()
        terminal.write(bytes("\u{1b}[?1000h\u{1b}[?1006h"))
        #expect(try terminal.encodeMouse(mouse(.press, .left, column: 9, row: 4, pressed: true)) == bytes("\u{1b}[<0;10;5M"))
        #expect(try terminal.encodeMouse(mouse(.release, .left, column: 9, row: 4)) == bytes("\u{1b}[<0;10;5m"))
    }

    // マウスの報告を有効にしていなければ何も送らない。
    @Test func nothingIsReportedWithoutMouseTracking() throws {
        let terminal = try terminal()
        #expect(try terminal.encodeMouse(mouse(.press, .left, column: 1, row: 1, pressed: true)).isEmpty)
        #expect(terminal.inputModes.mouseTracking == .none)
    }

    // ドラッグはボタンの報告（1002）以上、ボタンを押さない移動は any-event（1003）のときだけ報告する。
    @Test func motionIsReportedByTrackingMode() throws {
        let terminal = try terminal()
        terminal.write(bytes("\u{1b}[?1000h\u{1b}[?1006h"))
        #expect(terminal.inputModes.mouseTracking == .normal)
        #expect(try terminal.encodeMouse(mouse(.motion, .left, column: 2, row: 0, pressed: true)).isEmpty)

        terminal.write(bytes("\u{1b}[?1002h"))
        #expect(terminal.inputModes.mouseTracking == .button)
        #expect(try terminal.encodeMouse(mouse(.motion, .left, column: 2, row: 0, pressed: true)) == bytes("\u{1b}[<32;3;1M"))
        #expect(try terminal.encodeMouse(mouse(.motion, nil, column: 3, row: 0)).isEmpty)

        terminal.write(bytes("\u{1b}[?1003h"))
        #expect(terminal.inputModes.mouseTracking == .any)
        #expect(try terminal.encodeMouse(mouse(.motion, nil, column: 4, row: 0)) == bytes("\u{1b}[<35;5;1M"))
        // 同じセルの中の移動は送らない。
        var sameCell = mouse(.motion, nil, column: 4, row: 0)
        sameCell.x += 3
        #expect(try terminal.encodeMouse(sameCell).isEmpty)
    }

    // Scenario: Pixel positions — DECSET 1016 では、グリッドの左上からの device pixel で報告する。
    @Test func sgrPixelsReportsDevicePixels() throws {
        let terminal = try terminal()
        terminal.write(bytes("\u{1b}[?1000h\u{1b}[?1016h"))
        let point = surface.center(ofColumn: 9, row: 4)
        let click = MouseInput(action: .press, button: .left, x: point.x, y: point.y, anyButtonPressed: true, surface: surface)
        // 余白（8 px）を除いた位置。x = 9 * 16 + 8 = 152、y = 4 * 34 + 17 = 153
        #expect(try terminal.encodeMouse(click) == bytes("\u{1b}[<0;152;153M"))
    }

    // 右ボタン・中ボタンと、修飾キー。
    @Test func otherButtonsAndModifiers() throws {
        let terminal = try terminal()
        terminal.write(bytes("\u{1b}[?1000h\u{1b}[?1006h"))
        #expect(try terminal.encodeMouse(mouse(.press, .right, column: 0, row: 0, pressed: true)) == bytes("\u{1b}[<2;1;1M"))
        #expect(try terminal.encodeMouse(mouse(.press, .middle, column: 0, row: 0, pressed: true)) == bytes("\u{1b}[<1;1;1M"))
        var control = mouse(.press, .left, column: 0, row: 0, pressed: true)
        control.modifiers = .control
        #expect(try terminal.encodeMouse(control) == bytes("\u{1b}[<16;1;1M"))
    }

    // Mouse reports SHALL only be sent while the session is live.
    @MainActor
    @Test func mouseIsNotReportedDuringReplay() async throws {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", maxScrollback: 100, colors: nil, sink: sink)
        await controller.setViewGrid(.init(cols: 80, rows: 24, cellWidthPx: 16, cellHeightPx: 34))
        await controller.attach()
        await controller.receiveReplay(bytes("\u{1b}[?1000h\u{1b}[?1006h"), done: false)
        #expect(controller.inputModes.mouseTracking == .normal)
        controller.enqueueMouse(mouse(.press, .left, column: 0, row: 0, pressed: true))
        await controller.flushInput()
        #expect(sink.inputFrames.isEmpty)

        await controller.receiveReplay([], done: true)
        controller.enqueueMouse(mouse(.press, .left, column: 0, row: 0, pressed: true))
        await controller.flushInput()
        #expect(sink.inputFrames == [bytes("\u{1b}[<0;1;1M")])
    }

    // MARK: - Requirement: Scroll wheel and trackpad

    @Test func scrollRoutingOrder() {
        #expect(scrollTarget(mouseTracking: .normal, shift: false, alternateScreen: false) == .mouseReport)
        #expect(scrollTarget(mouseTracking: .any, shift: false, alternateScreen: true) == .mouseReport)
        #expect(scrollTarget(mouseTracking: .none, shift: false, alternateScreen: true) == .arrowKeys)
        #expect(scrollTarget(mouseTracking: .none, shift: false, alternateScreen: false) == .viewport)
        // Shift を押しているときは報告しない。
        #expect(scrollTarget(mouseTracking: .normal, shift: true, alternateScreen: false) == .viewport)
        #expect(scrollTarget(mouseTracking: .normal, shift: true, alternateScreen: true) == .arrowKeys)
    }

    // ゆっくりスクロールしても、溜めて 1 行ずつ動く。
    @Test func preciseDeltasAccumulateIntoLines() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.add(5, precise: true, cellHeight: 17) == 0)
        #expect(accumulator.add(5, precise: true, cellHeight: 17) == 0)
        #expect(accumulator.add(8, precise: true, cellHeight: 17) == 1)
        #expect(accumulator.add(35, precise: true, cellHeight: 17) == 2)
        // 向きが変わったら、前の端数は捨てる。
        #expect(accumulator.add(-10, precise: true, cellHeight: 17) == 0)
        #expect(accumulator.add(-10, precise: true, cellHeight: 17) == -1)
        accumulator.reset()
        #expect(accumulator.pending == 0)
    }

    @Test func wheelDeltasAreLines() {
        var accumulator = ScrollAccumulator()
        #expect(accumulator.add(1, precise: false, cellHeight: 17) == 1)
        #expect(accumulator.add(3, precise: false, cellHeight: 17) == 3)
        #expect(accumulator.add(-1, precise: false, cellHeight: 17) == -1)
        #expect(accumulator.add(0.5, precise: false, cellHeight: 17) == 0)
        #expect(accumulator.add(0.5, precise: false, cellHeight: 17) == 1)
    }

    /// viewport の 1 行目の文字列。
    private func firstVisibleLine(_ controller: TerminalController) async -> String {
        let snapshot = await controller.makeSnapshot(forceFull: true)
        let row = snapshot?.dirtyRows.first { $0.y == 0 }?.cells ?? []
        return row.map(\.text).joined()
    }

    private func liveController(_ sink: RecordingSink, maxScrollback: Int = 1000) async throws -> TerminalController {
        let controller = try TerminalController(sid: "s1", maxScrollback: maxScrollback, colors: nil, sink: sink)
        await controller.setViewGrid(.init(cols: 80, rows: 24, cellWidthPx: 16, cellHeightPx: 34))
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()
        return controller
    }

    private func scroll(_ lines: Int, shift: Bool = false) -> ScrollInput {
        let point = surface.center(ofColumn: 9, row: 4)
        return ScrollInput(lines: lines, x: point.x, y: point.y, modifiers: shift ? .shift : [], surface: surface)
    }

    // Scenario: Scrollback in a shell / Output while scrolled back
    @MainActor
    @Test func shellScrollMovesTheViewportAndOutputDoesNotMoveIt() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes((0..<100).map { "line \($0)\r\n" }.joined()))
        #expect(await firstVisibleLine(controller) == "line 77")

        controller.enqueueScroll(scroll(10))
        await controller.flushInput()
        #expect(await firstVisibleLine(controller) == "line 67")
        #expect(sink.inputFrames.isEmpty)

        await controller.receiveOutput(bytes("more 1\r\nmore 2\r\n"))
        #expect(await firstVisibleLine(controller) == "line 67")

        controller.enqueueScroll(scroll(-3))
        await controller.flushInput()
        #expect(await firstVisibleLine(controller) == "line 70")
        // 最下部より先には動かない。
        controller.enqueueScroll(scroll(-1000))
        await controller.flushInput()
        #expect(await controller.withTerminal { $0.isViewportAtBottom })
        #expect(sink.inputFrames.isEmpty)
    }

    // viewport を上に動かせるのは、最新の `scrollback_lines` 行まで（phase2 design D5）。
    @MainActor
    @Test func viewportStopsAtTheScrollbackLimit() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink, maxScrollback: 100)
        await controller.receiveOutput(bytes((0..<500).map { "line \($0)\r\n" }.joined()))
        #expect(await controller.withTerminal { $0.scrollbackRows } == 100)

        controller.enqueueScroll(scroll(10_000))
        await controller.flushInput()
        // 画面は line 477〜499 と空の行。見せるスクロールバックは、その上の 100 行（line 377〜476）。
        #expect(await firstVisibleLine(controller) == "line 377")

        // それ以上は上に動かない。
        controller.enqueueScroll(scroll(1))
        await controller.flushInput()
        #expect(await firstVisibleLine(controller) == "line 377")
    }

    // Scenario: Pager in alternate screen — less で 3 行下にスクロールすると、下矢印が 3 回届く。
    @MainActor
    @Test func alternateScreenScrollSendsArrowKeys() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes("\u{1b}[?1049h"))
        controller.enqueueScroll(scroll(-3))
        await controller.flushInput()
        #expect(sink.inputFrames == [bytes("\u{1b}[B\u{1b}[B\u{1b}[B")])

        // application cursor mode に従う。
        sink.removeAll()
        await controller.receiveOutput(bytes("\u{1b}[?1h"))
        controller.enqueueScroll(scroll(2))
        await controller.flushInput()
        #expect(sink.inputFrames == [bytes("\u{1b}OA\u{1b}OA")])
    }

    // Scenario: Program with mouse reporting — htop にはホイールとして報告し、viewport は動かさない。
    @MainActor
    @Test func mouseReportingProgramsReceiveWheelEvents() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes((0..<100).map { "line \($0)\r\n" }.joined()))
        await controller.receiveOutput(bytes("\u{1b}[?1000h\u{1b}[?1006h"))
        controller.enqueueScroll(scroll(2))
        controller.enqueueScroll(scroll(-1))
        await controller.flushInput()
        #expect(sink.inputFrames == [bytes("\u{1b}[<64;10;5M\u{1b}[<64;10;5M\u{1b}[<65;10;5M")])
        #expect(await controller.withTerminal { $0.isViewportAtBottom })
    }
}
