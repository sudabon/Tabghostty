import Foundation
import os
import Testing
@testable import TerminalCore
@testable import DaemonClient

/// spec: terminal-session「All sessions stay attached」「All sessions share the window's grid size」と、
/// spec: tab-operations のタブの操作（phase3）をモックのデーモンで確かめる。
@MainActor
@Suite(.serialized) struct AllSessionsAttachedTests {
    private let grid = TerminalController.GridSize(cols: 100, rows: 30, cellWidthPx: 16, cellHeightPx: 34)

    private func makeCoordinator(port: Int, api: any SessionAPI = MockSessionAPI()) -> SessionCoordinator {
        let connection = WSConnection(port: port, token: "token", sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let coordinator = SessionCoordinator(connection: connection, api: api) { sid, sink in
            try TerminalController(sid: sid, cols: 100, rows: 30, maxScrollback: 1000, colors: nil, sink: sink)
        }
        coordinator.viewGrid = grid
        return coordinator
    }

    private func screen(_ coordinator: SessionCoordinator, _ sid: String) async -> String {
        await coordinator.controller(for: sid)?.plainText() ?? ""
    }

    private nonisolated func frames(_ daemon: MockDaemon, type: String) -> [[String: Any]] {
        daemon.server.receivedObjects.filter { $0["t"] as? String == type }
    }

    private nonisolated func resizes(_ daemon: MockDaemon) -> [String] {
        frames(daemon, type: "resize").map { "\($0["sid"] as? String ?? "?"):\($0["cols"] as? Int ?? 0)x\($0["rows"] as? Int ?? 0)" }
    }

    // MARK: - 1.1 一覧との差分で attach する・手放す

    // Scenario: New session from browser / Removed session
    @Test func everyListedSessionIsAttachedAndRemovedOnesAreReleased() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1"), MockDaemon.session("s2")]) { sid, _ in
            [MockDaemon.replay(sid, "I am \(sid)", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil {
            let first = await self.screen(coordinator, "s1")
            let second = await self.screen(coordinator, "s2")
            return first == "I am s1" && second == "I am s2"
        })
        #expect(daemon.attachCount("s1") == 1)
        #expect(daemon.attachCount("s2") == 1)
        #expect(coordinator.activeController?.sid == "s1")

        // ブラウザ版でセッションが作られた。
        daemon.setSessions([MockDaemon.session("s1"), MockDaemon.session("s2"), MockDaemon.session("s3")])
        #expect(await waitUntil { await self.screen(coordinator, "s3") == "I am s3" })
        #expect(daemon.attachCount("s3") == 1)
        // 既にあるセッションには attach し直さない。
        #expect(daemon.attachCount("s1") == 1)
        #expect(daemon.attachCount("s2") == 1)

        // s2 が閉じられた。端末の状態を手放す。
        let released = WeakController(coordinator.controller(for: "s2"))
        #expect(released.value != nil)
        daemon.setSessions([MockDaemon.session("s1"), MockDaemon.session("s3")])
        #expect(await waitUntil { await MainActor.run { coordinator.attachedSessionIDs == ["s1", "s3"] } })
        #expect(coordinator.controller(for: "s2") == nil)
        #expect(await waitUntil { released.value == nil })
        // 消えたセッションの output は捨てる（落ちない）。
        daemon.server.sendToLatest(json: MockDaemon.output("s2", "late"))
        daemon.server.sendToLatest(json: MockDaemon.output("s1", "!"))
        #expect(await waitUntil { await self.screen(coordinator, "s1") == "I am s1!" })
    }

    // MARK: - 1.2 裏のタブの出力を、切り替えた直後に replay なしで出す

    // Scenario: Background output / Switch tabs
    @Test func backgroundOutputIsShownWithoutReplayWhenSelected() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1"), MockDaemon.session("s2")]) { sid, _ in
            [MockDaemon.replay(sid, "$ ", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        var shown: [String?] = []
        coordinator.onActiveControllerChange = { shown.append($0?.sid) }
        await coordinator.start()
        defer { Task { await coordinator.stop() } }
        #expect(await waitUntil { await self.screen(coordinator, "s2") == "$" })
        #expect(coordinator.activeController?.sid == "s1")

        // 裏のタブ（s2）が 100 行出力する。
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\r\n")
        daemon.server.sendToLatest(json: MockDaemon.output("s2", lines))
        #expect(await waitUntil { await self.screen(coordinator, "s2").hasSuffix("line 100") })

        let attachesBefore = frames(daemon, type: "attach").count
        coordinator.activate("s2")
        #expect(coordinator.activeController === coordinator.controller(for: "s2"))
        #expect(shown.last == "s2")
        #expect(await screen(coordinator, "s2").hasSuffix("line 100"))
        // スクロールバックにも残っている（画面は 30 行なので、先頭の行はスクロールバックにある）。
        let scrollback = await coordinator.controller(for: "s2")?.withTerminal { $0.scrollbackRows } ?? 0
        #expect(scrollback >= 70)
        try await Task.sleep(for: .milliseconds(100))
        // attach（replay）は増えない。
        #expect(frames(daemon, type: "attach").count == attachesBefore)
        #expect(daemon.attachCount("s2") == 1)
    }

    // MARK: - 1.3 グリッドサイズ

    // Scenario: Window resized with background tabs / Re-assert size on activation
    @Test func gridChangesResizeEveryLiveSessionAndActivationReassertsTheSize() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("a"), MockDaemon.session("b"), MockDaemon.session("c")]) { sid, _ in
            [MockDaemon.replay(sid, "ready", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        // live になったときに、各セッションに 1 回ずつ送る。
        #expect(await waitUntil { Set(self.resizes(daemon)) == ["a:100x30", "b:100x30", "c:100x30"] })
        #expect(resizes(daemon).count == 3)

        daemon.server.clearReceived()
        coordinator.viewGrid = TerminalController.GridSize(cols: 120, rows: 40, cellWidthPx: 16, cellHeightPx: 34)
        #expect(await waitUntil { self.resizes(daemon).count == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(resizes(daemon).sorted() == ["a:120x40", "b:120x40", "c:120x40"])
        // 裏のタブの端末も新しいサイズになっている。
        let size = await coordinator.controller(for: "c")?.withTerminal { ($0.cols, $0.rows) }
        #expect(size?.0 == 120)
        #expect(size?.1 == 40)

        // 同じサイズなら送らない。
        daemon.server.clearReceived()
        coordinator.viewGrid = TerminalController.GridSize(cols: 120, rows: 40, cellWidthPx: 16, cellHeightPx: 34)
        try await Task.sleep(for: .milliseconds(100))
        #expect(resizes(daemon).isEmpty)

        // タブを切り替えたら、そのセッションにだけ送り直す（ほかのクライアントが変えているかもしれない）。
        coordinator.activate("b")
        #expect(await waitUntil { self.resizes(daemon) == ["b:120x40"] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(resizes(daemon) == ["b:120x40"])
        #expect(!daemon.server.receivedTypes.contains("attach"))
    }

    // 再接続したら、一覧に残っているセッションだけを attach し直す（spec: terminal-session「Re-attach after reconnect」）。
    @Test func reconnectReattachesOnlySessionsStillListed() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1"), MockDaemon.session("s2")]) { sid, _ in
            [MockDaemon.replay(sid, "hi \(sid)", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }
        #expect(await waitUntil { await self.screen(coordinator, "s2") == "hi s2" })

        // デーモンが再起動して、s2 が無くなった。
        daemon.setSessions([MockDaemon.session("s1")], broadcast: false)
        daemon.server.dropAll()
        #expect(await waitUntil { daemon.attachCount("s1") == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(daemon.attachCount("s2") == 1)
        #expect(coordinator.attachedSessionIDs == ["s1"])
        #expect(await waitUntil { await self.screen(coordinator, "s1") == "hi s1" })
    }

    // MARK: - 5.1 / 5.5 タブの操作

    // Scenario: New tab / duplicate / restart — 返ってきたセッションがアクティブになる。
    @Test func createdDuplicatedAndRestartedSessionsBecomeActive() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1"), MockDaemon.session("dead", state: "exited")]) { sid, _ in
            [MockDaemon.replay(sid, "I am \(sid)", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let api = MockSessionAPI()
        api.onCreate = {
            daemon.setSessions([MockDaemon.session("s1"), MockDaemon.session("dead", state: "exited"), MockDaemon.session("new")])
            return SessionInfo(id: "new", state: "starting")
        }
        api.onDuplicate = { _ in
            daemon.setSessions([MockDaemon.session("s1"), MockDaemon.session("dead", state: "exited"), MockDaemon.session("new"), MockDaemon.session("dup")])
            return SessionInfo(id: "dup")
        }
        api.onRestart = { _ in
            daemon.setSessions([MockDaemon.session("s1"), MockDaemon.session("re"), MockDaemon.session("new"), MockDaemon.session("dup")])
            return SessionInfo(id: "re")
        }
        let coordinator = makeCoordinator(port: daemon.server.port, api: api)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }
        #expect(await waitUntil { await self.screen(coordinator, "s1") == "I am s1" })

        await coordinator.createSession()
        #expect(coordinator.store.activeSessionID == "new")
        #expect(await waitUntil { await MainActor.run { coordinator.activeController?.sid == "new" } })
        #expect(await waitUntil { await self.screen(coordinator, "new") == "I am new" })

        await coordinator.duplicateSession("s1")
        #expect(coordinator.store.activeSessionID == "dup")
        #expect(await waitUntil { await MainActor.run { coordinator.activeController?.sid == "dup" } })

        // 実行中・idle のセッションは再起動しない。
        await coordinator.restartSession("s1")
        #expect(!api.recorded.contains("restart:s1"))

        await coordinator.restartSession("dead")
        #expect(coordinator.store.activeSessionID == "re")
        #expect(await waitUntil { await MainActor.run { coordinator.activeController?.sid == "re" } })
        #expect(api.recorded == ["create", "duplicate:s1", "restart:dead"])
        // タブの一覧は、デーモンの `sessions` でだけ変わる。
        #expect(coordinator.store.sessions.map(\.id) == ["s1", "re", "new", "dup"])
    }

    @Test func failedCreationKeepsTheActiveSessionAndReportsAnError() async throws {
        let api = MockSessionAPI()
        api.failing = ["create"]
        let coordinator = makeCoordinator(port: try await unusedLoopbackPort(), api: api)
        var messages: [String] = []
        coordinator.onTransientMessage = { messages.append($0) }
        coordinator.store.apply(.sessions([SessionInfo(id: "s1")]))
        await coordinator.createSession()
        #expect(coordinator.store.activeSessionID == "s1")
        #expect(messages == ["create failed"])
    }

    // Scenario: Mute / Failure
    @Test func muteIsAppliedImmediatelyAndRevertedOnFailure() async throws {
        let api = MockSessionAPI()
        let coordinator = makeCoordinator(port: try await unusedLoopbackPort(), api: api)
        var messages: [String] = []
        coordinator.onTransientMessage = { messages.append($0) }
        coordinator.store.apply(.sessions([SessionInfo(id: "a"), SessionInfo(id: "b")]))

        await coordinator.toggleNotificationsMuted("a")
        #expect(coordinator.store.sessions[0].notificationsMuted)
        #expect(api.recorded == ["mute:a:true"])
        #expect(messages.isEmpty)

        // 失敗したら元に戻し、メッセージを出す。
        api.failing = ["mute"]
        var observed: [Bool] = []
        coordinator.store.onChange = { observed.append(coordinator.store.sessions[1].notificationsMuted) }
        await coordinator.toggleNotificationsMuted("b")
        // 送る前に、すぐ表示を変えている。
        #expect(observed == [true, false])
        #expect(coordinator.store.sessions[1].notificationsMuted == false)
        #expect(api.recorded == ["mute:a:true", "mute:b:true"])
        #expect(messages == ["mute failed"])
    }

    @Test func closeMemoAndReorderCallTheAPI() async throws {
        let api = MockSessionAPI()
        let coordinator = makeCoordinator(port: try await unusedLoopbackPort(), api: api)
        var messages: [String] = []
        coordinator.onTransientMessage = { messages.append($0) }
        coordinator.store.apply(.sessions([SessionInfo(id: "a"), SessionInfo(id: "b"), SessionInfo(id: "c")]))

        await coordinator.closeSession("b")
        try await coordinator.updateMemo("a", memo: "レビュー対応")
        await coordinator.reorderSessions(["c", "a", "b"])
        #expect(api.recorded == ["delete:b", "memo:a:レビュー対応", "order:c,a,b"])
        // 並びはデーモンの `sessions` を待つ（ローカルでは変えない）。
        #expect(coordinator.store.sessions.map(\.id) == ["a", "b", "c"])

        api.failing = ["memo"]
        await #expect(throws: MockSessionAPI.Failure.self) { try await coordinator.updateMemo("a", memo: "x") }
        #expect(messages == ["memo failed"])
    }

    // `notify` フレームは store のイベントになる（phase3 tasks 4.1）。
    @Test func notifyFramesBecomeStoreEvents() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1")]) { sid, _ in
            [MockDaemon.replay(sid, "", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        var events: [SessionEvent] = []
        coordinator.store.onEvent = { events.append($0) }
        await coordinator.start()
        defer { Task { await coordinator.stop() } }
        #expect(await waitUntil { await MainActor.run { coordinator.store.hasReceivedSessions } })

        daemon.server.sendToLatest(json: ["t": "notify", "sid": "s1", "title": "Claude Code", "body": "Waiting for approval"])
        #expect(await waitUntil { await MainActor.run { events.count == 1 } })
        #expect(events == [.agentWaiting(sid: "s1", title: "Claude Code", body: "Waiting for approval")])
    }
}

/// 端末が手放されたことを確かめる弱い参照。
private final class WeakController: Sendable {
    weak let value: TerminalController?
    init(_ value: TerminalController?) { self.value = value }
}

/// spec: terminal-rendering「Responsiveness under heavy output」— 受信ループは書き込みを待たない（phase5 design D2）。
@MainActor
@Suite struct ReceiveLoopDoesNotWaitTests {
    final class ConnectedSink: TerminalFrameSink, @unchecked Sendable {
        func enqueue(_ frame: TerminalOutgoingFrame) -> Bool { true }
    }

    @Test func outputFramesAreQueuedWithoutWaitingForTheWrite() async throws {
        let sink = ConnectedSink()
        let coordinator = SessionCoordinator(connection: WSConnection(port: 1, token: "t"), api: MockSessionAPI()) { sid, _ in
            try TerminalController(sid: sid, cols: 160, rows: 50, maxScrollback: 1000, colors: nil, sink: sink)
        }
        await coordinator.handle(.frame(.sessions([SessionInfo(id: "busy"), SessionInfo(id: "quiet")])))
        await coordinator.handle(.frame(.replay(sid: "busy", data: [], done: true)))
        await coordinator.handle(.frame(.replay(sid: "quiet", data: [], done: true)))
        let busy = try #require(coordinator.controller(for: "busy"))
        let quiet = try #require(coordinator.controller(for: "quiet"))
        await busy.waitUntilIncomingIsWritten()
        await quiet.waitUntilIncomingIsWritten()

        let line = Array("0123456789 the quick brown fox jumps over the lazy dog\r\n".utf8)
        var big: [UInt8] = []
        while big.count < 32 << 20 { big += line }
        await coordinator.handle(.frame(.output(sid: "busy", data: big)))
        // 書き込みを待たずに戻るので、次のフレーム（ほかのセッションのエコー）をすぐに処理できる。
        #expect(busy.pendingOutputBytes > 0)
        await coordinator.handle(.frame(.output(sid: "quiet", data: Array("echo".utf8))))
        await quiet.waitUntilIncomingIsWritten()
        #expect(await quiet.plainText() == "echo")
        await busy.waitUntilIncomingIsWritten()
        #expect(busy.pendingOutputBytes == 0)
    }
}
