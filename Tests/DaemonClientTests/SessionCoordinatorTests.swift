import Foundation
import Network
import os
import Testing
import TerminalCore
@testable import DaemonClient

/// モックのデーモン（WebSocket）。`attach` への応答をテストごとに決める。
final class MockDaemon: @unchecked Sendable {
    /// デーモンのセッション 1 つ。
    struct Session: Sendable {
        var id: String
        var state = "idle"
        var cwd = "/Users/me"

        var json: [String: Any] {
            ["id": id, "order": 0, "cwd": cwd, "command": "", "state": state, "exit": NSNull(), "integrated": true,
             "memo": "", "agent": "", "agent_state": "none"]
        }
    }

    struct State {
        var sessions: [Session] = []
        var attachCount: [String: Int] = [:]
    }

    /// `attach` を受けたときに送るフレーム（sid と、その sid への何回目の attach か）。
    typealias AttachResponder = @Sendable (_ sid: String, _ count: Int) -> [[String: Any]]

    let server: MockWebSocketServer
    private let state: OSAllocatedUnfairLock<State>

    init(sessions: [Session], onAttach: @escaping AttachResponder) throws {
        let state = OSAllocatedUnfairLock(initialState: State())
        state.withLock { $0.sessions = sessions }
        self.state = state
        server = try MockWebSocketServer(
            onConnect: { server, connection in
                let list = state.withLock { $0.sessions }
                server.send(json: ["t": "sessions", "list": list.map(\.json)], on: connection)
            },
            onMessage: { server, connection, text in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                      object["t"] as? String == "attach", let sid = object["sid"] as? String else { return }
                let count = state.withLock { state -> Int in
                    state.attachCount[sid, default: 0] += 1
                    return state.attachCount[sid]!
                }
                for frame in onAttach(sid, count) {
                    server.send(json: frame, on: connection)
                }
            }
        )
    }

    func start() async throws { try await server.start() }
    func stop() { server.stop() }

    /// セッション一覧を変えて、つながっているクライアントへ送る。
    func setSessions(_ sessions: [Session], broadcast: Bool = true) {
        state.withLock { $0.sessions = sessions }
        if broadcast { server.sendToLatest(json: ["t": "sessions", "list": sessions.map(\.json)]) }
    }

    func attachCount(_ sid: String) -> Int { state.withLock { $0.attachCount[sid] ?? 0 } }

    static func session(_ id: String, state: String = "idle", cwd: String = "/Users/me") -> Session {
        Session(id: id, state: state, cwd: cwd)
    }

    static func replay(_ sid: String, _ text: String, done: Bool) -> [String: Any] {
        ["t": "replay", "sid": sid, "data": Data(text.utf8).base64EncodedString(), "done": done]
    }

    static func output(_ sid: String, _ text: String) -> [String: Any] {
        ["t": "output", "sid": sid, "data": Data(text.utf8).base64EncodedString()]
    }
}

/// クリップボードへの書き込みを記録する。
final class RecordingClipboard: TerminalClipboard, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    var writes: [String] { state.withLock { $0 } }
    func write(_ text: String) { state.withLock { $0.append(text) } }
}

/// REST の代わり。呼ばれた操作を記録する。
final class MockSessionAPI: SessionAPI, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let calls = OSAllocatedUnfairLock(initialState: [String]())
    var onCreate: @Sendable () -> SessionInfo = { SessionInfo(id: "created") }
    var onRestart: @Sendable (String) -> SessionInfo = { _ in SessionInfo(id: "restarted") }
    var onDuplicate: @Sendable (String) -> SessionInfo = { _ in SessionInfo(id: "duplicated") }
    /// 失敗させる操作（`calls` に記録する名前の先頭。"mute" など）。
    var failing: Set<String> = []

    var recorded: [String] { calls.withLock { $0 } }

    private func record(_ call: String, kind: String) throws {
        calls.withLock { $0.append(call) }
        if failing.contains(kind) { throw Failure(message: "\(kind) failed") }
    }

    func createSession(cwd: String?) async throws -> SessionInfo {
        try record("create", kind: "create")
        return onCreate()
    }

    func restartSession(id: String) async throws -> SessionInfo {
        try record("restart:\(id)", kind: "restart")
        return onRestart(id)
    }

    func duplicateSession(id: String) async throws -> SessionInfo {
        try record("duplicate:\(id)", kind: "duplicate")
        return onDuplicate(id)
    }

    func deleteSession(id: String) async throws {
        try record("delete:\(id)", kind: "delete")
    }

    func updateSessionMemo(id: String, memo: String) async throws -> SessionInfo {
        try record("memo:\(id):\(memo)", kind: "memo")
        return SessionInfo(id: id, memo: memo)
    }

    func setSessionNotificationsMuted(id: String, muted: Bool) async throws -> SessionInfo {
        try record("mute:\(id):\(muted)", kind: "mute")
        return SessionInfo(id: id, notificationsMuted: muted)
    }

    func reorderSessions(ids: [String]) async throws {
        try record("order:\(ids.joined(separator: ","))", kind: "order")
    }
}

/// spec: terminal-session、tab-operations（起動時のセッション確保）をモックのデーモンで確かめる。
@MainActor
@Suite(.serialized) struct SessionCoordinatorTests {
    private let grid = TerminalController.GridSize(cols: 100, rows: 30, cellWidthPx: 16, cellHeightPx: 34)

    private func makeCoordinator(
        port: Int,
        api: any SessionAPI = MockSessionAPI(),
        clipboard: (any TerminalClipboard)? = nil
    ) -> SessionCoordinator {
        let connection = WSConnection(port: port, token: "token", sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let coordinator = SessionCoordinator(connection: connection, api: api) { sid, sink in
            try TerminalController(sid: sid, maxScrollback: 1000, colors: nil, sink: sink, clipboard: clipboard)
        }
        coordinator.viewGrid = grid
        return coordinator
    }

    private func screen(_ coordinator: SessionCoordinator) async -> String {
        await coordinator.activeController?.plainText() ?? ""
    }

    private nonisolated func types(_ daemon: MockDaemon) -> [String] { daemon.server.receivedTypes }

    // Requirement: Attach starts a fresh replay — Scenario: Replay then live
    @Test func replayInThreeChunksThenOutput() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1")]) { sid, _ in
            [
                MockDaemon.replay(sid, "line1\r\n", done: false),
                MockDaemon.replay(sid, "line2\r\n", done: false),
                MockDaemon.replay(sid, "line3", done: true),
                MockDaemon.output(sid, "\r\nlive"),
            ]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { await self.screen(coordinator) == "line1\nline2\nline3\nlive" })
        #expect(coordinator.activeController?.sid == "s1")
        #expect(await coordinator.activeController?.phase == .live)
        #expect(types(daemon) == ["attach", "resize"])
        let resize = daemon.server.receivedObjects.last
        #expect(resize?["cols"] as? Int == 100)
        #expect(resize?["rows"] as? Int == 30)
        #expect(resize?["sid"] as? String == "s1")
    }

    // Requirement: No terminal responses during replay（SPEC §8.1）
    @Test func replayedQueriesAreNotAnsweredButLiveOnesAre() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1")]) { sid, _ in
            [
                MockDaemon.replay(sid, "$ \u{1b}[c", done: false),
                MockDaemon.replay(sid, "\u{1b}[6n", done: true),
            ]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { self.types(daemon) == ["attach", "resize"] })
        try await Task.sleep(for: .milliseconds(100))
        #expect(types(daemon) == ["attach", "resize"])

        daemon.server.sendToLatest(json: MockDaemon.output("s1", "\u{1b}[c"))
        #expect(await waitUntil { self.types(daemon).count == 3 })
        let input = daemon.server.receivedObjects.last
        #expect(input?["t"] as? String == "input")
        #expect((input?["data"] as? String).flatMap { Data(base64Encoded: $0) } == Data("\u{1b}[?62;22c".utf8))
    }

    // spec: terminal-clipboard「OSC 52 clipboard access」— Scenario: Replayed clipboard write / Read refused / Remote copy
    @Test func osc52WritesOnlyWhenLiveAndReadsAreNeverAnswered() async throws {
        let history = Data("from history".utf8).base64EncodedString()
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1")]) { sid, _ in
            [MockDaemon.replay(sid, "\u{1b}]52;c;\(history)\u{07}\u{1b}]52;c;?\u{07}$ ", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let clipboard = RecordingClipboard()
        let coordinator = makeCoordinator(port: daemon.server.port, clipboard: clipboard)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { self.types(daemon) == ["attach", "resize"] })
        try await Task.sleep(for: .milliseconds(100))
        // replay の中の書き込みは pasteboard を変えず、読み取りには応答しない。
        #expect(clipboard.writes.isEmpty)
        #expect(types(daemon) == ["attach", "resize"])

        daemon.server.sendToLatest(json: MockDaemon.output("s1", "\u{1b}]52;c;?\u{07}\u{1b}]52;c;\(Data("hello".utf8).base64EncodedString())\u{07}"))
        #expect(await waitUntil { clipboard.writes == ["hello"] })
        try await Task.sleep(for: .milliseconds(100))
        // live でも読み取りには応答しない（input フレームを送らない）。
        #expect(types(daemon) == ["attach", "resize"])
    }

    // Requirement: Recover from attach overflow — Scenario: Overflow during heavy output
    @Test func attachOverflowReattachesWithoutDuplicates() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1")]) { sid, count in
            if count == 1 {
                // デーモンは replay を送り切ってから、溜めた出力が溢れたことを知らせる。その後の出力は直接送る。
                return [
                    MockDaemon.replay(sid, "one\r\n", done: false),
                    MockDaemon.replay(sid, "two\r\n", done: true),
                    ["t": "error", "sid": sid, "code": "attach_overflow",
                     "message": "Live output overflowed during attach; re-attach required"],
                    MockDaemon.output(sid, "stale\r\n"),
                ]
            }
            return [
                MockDaemon.replay(sid, "one\r\ntwo\r\nstale\r\n", done: true),
                MockDaemon.output(sid, "fresh"),
            ]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        let messages = OSAllocatedUnfairLock(initialState: [String]())
        coordinator.onTransientMessage = { message in messages.withLock { $0.append(message) } }
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { await self.screen(coordinator) == "one\ntwo\nstale\nfresh" })
        #expect(daemon.attachCount("s1") == 2)
        #expect(types(daemon) == ["attach", "resize", "attach", "resize"])
        #expect(messages.withLock { $0 } == ["Live output overflowed during attach; re-attach required"])
    }

    // Requirement: Re-attach after reconnect — Scenario: Shell input line stays clean
    @Test func reconnectReattachesAndResendsSize() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1")]) { sid, _ in
            [MockDaemon.replay(sid, "welcome\r\n$ \u{1b}[c\u{1b}[6n", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { self.types(daemon) == ["attach", "resize"] })
        let controller = coordinator.activeController

        // デーモンの再起動を真似る。
        daemon.server.dropAll()
        #expect(await waitUntil { self.types(daemon) == ["attach", "resize", "attach", "resize"] })
        #expect(await waitUntil { await self.screen(coordinator) == "welcome\n$" })
        // 同じコントローラを使い続け、内容は重複しない。replay 中の問い合わせに応答しない。
        #expect(coordinator.activeController === controller)
        #expect(!types(daemon).contains("input"))
        #expect(daemon.server.connectCount == 2)
        #expect(coordinator.isConnected)
    }

    // Requirement: Active session selection — Scenario: Active session removed elsewhere
    @Test func activeSessionRemovedElsewhereSwitchesToTheFirst() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1"), MockDaemon.session("s2")]) { sid, _ in
            [MockDaemon.replay(sid, "I am \(sid)", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { await self.screen(coordinator) == "I am s1" })
        coordinator.activate("s2")
        #expect(await waitUntil { await self.screen(coordinator) == "I am s2" })

        daemon.setSessions([MockDaemon.session("s3"), MockDaemon.session("s1")])
        #expect(await waitUntil { await self.screen(coordinator) == "I am s3" })
        // 表示していないセッションの output は捨てる。
        daemon.server.sendToLatest(json: MockDaemon.output("s1", "ignored"))
        daemon.server.sendToLatest(json: MockDaemon.output("s3", "!"))
        #expect(await waitUntil { await self.screen(coordinator) == "I am s3!" })
    }

    // Requirement: Bootstrap a usable session on startup — Scenario: No sessions
    @Test func bootstrapCreatesASessionWhenThereAreNone() async throws {
        let daemon = try MockDaemon(sessions: []) { sid, _ in [MockDaemon.replay(sid, "fresh shell", done: true)] }
        try await daemon.start()
        defer { daemon.stop() }
        let api = MockSessionAPI()
        api.onCreate = {
            daemon.setSessions([MockDaemon.session("new", cwd: "/Users/me")])
            return SessionInfo(id: "new", cwd: "/Users/me", state: "starting")
        }
        let coordinator = makeCoordinator(port: daemon.server.port, api: api)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { await self.screen(coordinator) == "fresh shell" })
        #expect(api.calls.withLock { $0 } == ["create"])
        #expect(coordinator.store.activeSessionID == "new")
    }

    // Scenario: Exited first session
    @Test func bootstrapRestartsAnExitedFirstSession() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("old", state: "exited"), MockDaemon.session("other")]) { sid, _ in
            [MockDaemon.replay(sid, "I am \(sid)", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let api = MockSessionAPI()
        api.onRestart = { id in
            daemon.setSessions([MockDaemon.session("restarted"), MockDaemon.session("other")])
            return SessionInfo(id: "restarted")
        }
        let coordinator = makeCoordinator(port: daemon.server.port, api: api)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { await self.screen(coordinator) == "I am restarted" })
        #expect(api.calls.withLock { $0 } == ["restart:old"])
        #expect(coordinator.store.activeSessionID == "restarted")
    }

    // Scenario: Reconnect does not create sessions
    @Test func reconnectDoesNotBootstrapAgain() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session("s1")]) { sid, _ in
            [MockDaemon.replay(sid, "hi", done: true)]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let api = MockSessionAPI()
        let coordinator = makeCoordinator(port: daemon.server.port, api: api)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }
        #expect(await waitUntil { await self.screen(coordinator) == "hi" })

        // セッションが閉じられ、その後デーモンが再起動した。
        daemon.setSessions([], broadcast: false)
        daemon.server.dropAll()
        #expect(await waitUntil {
            await MainActor.run { daemon.server.connectCount == 2 && coordinator.store.sessions.isEmpty && coordinator.isConnected }
        })
        try await Task.sleep(for: .milliseconds(200))
        #expect(api.calls.withLock { $0 }.isEmpty)
        #expect(coordinator.activeController == nil)
    }
}
