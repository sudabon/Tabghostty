import os
import Testing
@testable import TerminalCore

/// spec: terminal-rendering「Synchronized output」、phase5 design D4。
@Suite struct SynchronizedOutputTests {
    private func liveController() async throws -> TerminalController {
        let controller = try TerminalController(sid: "s1", cols: 20, rows: 4, maxScrollback: 10, colors: nil, sink: RecordingSink())
        await controller.attach()
        await controller.receiveReplay(bytes("old"), done: true)
        _ = await controller.makeSnapshot(forceFull: true)
        return controller
    }

    private func text(_ snapshot: FrameSnapshot?) -> [String] {
        (snapshot?.dirtyRows ?? []).map { row in row.cells.map(\.text).joined() }
    }

    @Test func callbackFollowsTheMode() throws {
        let terminal = try VTTerminal(cols: 10, rows: 2, maxScrollback: 0)
        #expect(!terminal.isRenderHeld)
        terminal.write(bytes("\u{1b}[?2026h"))
        #expect(terminal.isRenderHeld)
        terminal.write(bytes("\u{1b}[?2026l"))
        #expect(!terminal.isRenderHeld)
        terminal.write(bytes("\u{1b}[?2026h"))
        terminal.reset()
        #expect(!terminal.isRenderHeld)
    }

    // Scenario: Flicker-free redraw — 同期中に dirty になっても描かず、解除したら完成した画面だけを描く。
    @Test func intermediateStatesAreNotPresented() async throws {
        let controller = try await liveController()
        await controller.receiveOutput(bytes("\u{1b}[?2026h\u{1b}[2J\u{1b}[Hhalf"))
        #expect(controller.isRenderHeld)
        #expect(!controller.needsRender)
        #expect(await controller.makeSnapshot() == nil)
        #expect(await controller.makeSnapshot(forceFull: true) == nil)

        await controller.receiveOutput(bytes(" done\u{1b}[?2026l"))
        #expect(!controller.isRenderHeld)
        #expect(controller.needsRender)
        let snapshot = try #require(await controller.makeSnapshot())
        #expect(text(snapshot).first == "half done")
    }

    @Test func releasingTheHoldNotifiesTheView() async throws {
        let controller = try await liveController()
        let notified = OSAllocatedUnfairLock(initialState: 0)
        controller.setRenderObserver { notified.withLock { $0 += 1 } }
        await controller.receiveOutput(bytes("\u{1b}[?2026hframe"))
        let duringHold = notified.withLock { $0 }
        await controller.receiveOutput(bytes("\u{1b}[?2026l"))
        // 保留している間に display link が止まっていても、解除されたら描き直せる。
        #expect(notified.withLock { $0 } > duringHold)
    }

    // 解除されないまま安全のためのタイムアウトが過ぎたら、そこまでの画面を描く。
    @Test func holdTimesOut() async throws {
        let controller = try await liveController()
        await controller.setRenderHoldTimeoutForTesting(.milliseconds(80))
        let notified = OSAllocatedUnfairLock(initialState: 0)
        controller.setRenderObserver { notified.withLock { $0 += 1 } }
        await controller.receiveOutput(bytes("\u{1b}[?2026hstuck"))
        #expect(await controller.makeSnapshot() == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!controller.isRenderHeld)
        #expect(controller.needsRender)
        #expect(notified.withLock { $0 } >= 1)
        #expect(text(try #require(await controller.makeSnapshot())).first == "oldstuck")
    }

    // リサイズすると保留は解かれる（ライブラリの動作。結果をすぐに見せる）。
    @Test func resizeReleasesTheHold() async throws {
        let controller = try await liveController()
        await controller.receiveOutput(bytes("\u{1b}[?2026hx"))
        #expect(controller.isRenderHeld)
        await controller.setViewGrid(TerminalController.GridSize(cols: 30, rows: 5, cellWidthPx: 16, cellHeightPx: 34))
        #expect(!controller.isRenderHeld)
        #expect(await controller.makeSnapshot() != nil)
    }
}
