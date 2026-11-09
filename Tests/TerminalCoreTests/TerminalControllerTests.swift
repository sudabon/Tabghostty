import Foundation
import Testing
@testable import TerminalCore

/// spec: terminal-session と terminal-input のうち、コントローラ単体で確かめられるもの。
@Suite struct TerminalControllerTests {
    private let grid = TerminalController.GridSize(cols: 100, rows: 30, cellWidthPx: 16, cellHeightPx: 34)

    private func makeController(_ sink: RecordingSink) throws -> TerminalController {
        try TerminalController(sid: "s1", maxScrollback: 1000, colors: nil, sink: sink)
    }

    private func key(_ character: String, keyCode: UInt16, modifiers: KeyInput.Modifiers = []) -> KeyInput {
        KeyInput.mac(
            keyCode: keyCode,
            characters: character,
            charactersIgnoringModifiers: character,
            unshiftedCharacters: character,
            modifiers: modifiers
        )!
    }

    // Requirement: Attach starts a fresh replay — Scenario: Replay then live
    @Test func replayThenLive() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.setViewGrid(grid)
        #expect(sink.frames.isEmpty)

        #expect(await controller.attach())
        #expect(await controller.phase == .replaying)
        await controller.receiveReplay(bytes("one\r\n"), done: false)
        await controller.receiveReplay(bytes("two\r\n"), done: false)
        #expect(sink.frames == [.attach(sid: "s1")])
        await controller.receiveReplay(bytes("three"), done: true)
        #expect(await controller.phase == .live)
        await controller.receiveOutput(bytes("\r\nlive"))

        #expect(await controller.plainText() == "one\ntwo\nthree\nlive")
        #expect(sink.frames == [.attach(sid: "s1"), .resize(sid: "s1", cols: 100, rows: 30)])
    }

    // Scenario: Empty ring buffer
    @Test func emptyReplayGoesLive() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.setViewGrid(grid)
        await controller.attach()
        await controller.receiveReplay([], done: true)
        #expect(await controller.phase == .live)
        #expect(await controller.plainText() == "")
        #expect(sink.frames.last == .resize(sid: "s1", cols: 100, rows: 30))
    }

    // attach すると前の内容は消える（reset してから replay を書く）。
    @Test func attachResetsTheTerminal() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.attach()
        await controller.receiveReplay(bytes("old content"), done: true)
        await controller.attach()
        #expect(await controller.plainText() == "")
        await controller.receiveReplay(bytes("new content"), done: true)
        #expect(await controller.plainText() == "new content")
    }

    // Requirement: No terminal responses during replay — Scenario: Historical query in replay / Same query when live
    @Test func responsesAreSuppressedDuringReplayAndSentWhenLive() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.attach()
        await controller.receiveReplay(bytes("$ \u{1b}[c\u{1b}[6n"), done: false)
        await controller.receiveReplay(bytes("\u{1b}[16t\u{1b}[>c"), done: true)
        #expect(sink.inputFrames.isEmpty)

        await controller.receiveOutput(bytes("\u{1b}[c"))
        #expect(sink.inputFrames == [bytes("\u{1b}[?62;22c")])
    }

    // Requirement: Effects handled by other components are ignored
    @Test func bellTitleAndNotificationsAreNotForwarded() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()
        await controller.receiveOutput(bytes("\u{1b}]9;done\u{07}\u{1b}]777;notify;t;b\u{07}\u{1b}]2;title\u{07}\u{07}x"))
        #expect(sink.frames.isEmpty)
        #expect(await controller.plainText() == "x")
    }

    // output は live のときだけ書く（attach より前にデーモンが送り出したものは replay に含まれている）。
    @Test func outputIsIgnoredUntilLive() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.receiveOutput(bytes("before attach"))
        await controller.attach()
        await controller.receiveOutput(bytes("stale"))
        await controller.receiveReplay(bytes("replayed"), done: true)
        await controller.receiveOutput(bytes(" live"))
        #expect(await controller.plainText() == "replayed live")
    }

    // Grid size follows the view: live でサイズが変わったときだけ resize を送る。
    @Test func resizeIsSentOnlyWhenLiveAndChanged() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.setViewGrid(grid)
        await controller.attach()
        await controller.setViewGrid(.init(cols: 90, rows: 30, cellWidthPx: 16, cellHeightPx: 34))
        #expect(sink.frames == [.attach(sid: "s1")])
        await controller.receiveReplay([], done: true)
        #expect(sink.frames.last == .resize(sid: "s1", cols: 90, rows: 30))

        sink.removeAll()
        // セルのピクセルサイズだけが変わった（ディスプレイの移動）: PTY のサイズは変わらないので送らない。
        await controller.setViewGrid(.init(cols: 90, rows: 30, cellWidthPx: 8, cellHeightPx: 17))
        #expect(sink.frames.isEmpty)
        await controller.setViewGrid(.init(cols: 91, rows: 30, cellWidthPx: 8, cellHeightPx: 17))
        #expect(sink.frames == [.resize(sid: "s1", cols: 91, rows: 30)])
    }

    // Requirement: Input batching and gating — Scenario: Fast typing
    @MainActor
    @Test func keysInOneRunLoopTurnAreSentAsOneFrame() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()

        controller.enqueueKey(key("l", keyCode: 0x25))
        controller.enqueueKey(key("s", keyCode: 0x01))
        controller.enqueueKey(key("\r", keyCode: 0x24))
        #expect(await waitFor { !sink.inputFrames.isEmpty })
        try await Task.sleep(for: .milliseconds(50))
        #expect(sink.inputFrames == [bytes("ls\r")])

        // Scenario: Interrupt
        controller.enqueueKey(key("c", keyCode: 0x08, modifiers: .control))
        #expect(await waitFor { sink.inputFrames.count == 2 })
        #expect(sink.inputFrames.last == [0x03])
    }

    // Scenario: Typing during replay
    @MainActor
    @Test func keysDuringReplayAreDropped() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.attach()
        controller.enqueueKey(key("x", keyCode: 0x07))
        try await Task.sleep(for: .milliseconds(50))
        await controller.flushKeys()
        await controller.receiveReplay([], done: true)
        await controller.flushKeys()
        #expect(sink.inputFrames.isEmpty)
    }

    // Scenario: Disconnected
    @MainActor
    @Test func keysWhileDisconnectedAreDroppedNotQueued() async throws {
        let sink = RecordingSink()
        let controller = try makeController(sink)
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()

        sink.connected = false
        await controller.connectionLost()
        controller.enqueueKey(key("x", keyCode: 0x07))
        try await Task.sleep(for: .milliseconds(50))

        // 再接続しても、切断中の入力は届かない。
        sink.connected = true
        await controller.attach()
        await controller.receiveReplay([], done: true)
        await controller.flushKeys()
        #expect(sink.inputFrames.isEmpty)
        #expect(sink.frames == [.attach(sid: "s1")])
    }

    private func waitFor(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
