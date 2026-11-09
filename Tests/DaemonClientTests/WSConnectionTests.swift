import Foundation
import os
import Testing
import TerminalCore
@testable import DaemonClient

/// spec: daemon-connection「Authenticated requests」「Session list synchronization」「Keepalive and reconnection」。
@Suite struct WSConnectionTests {
    private let token = "c0ffee-websocket-token-0000"

    /// ハンドラが受け取ったイベントを記録する。
    final class EventLog: @unchecked Sendable {
        private let events = OSAllocatedUnfairLock(initialState: [WSConnection.Event]())

        var all: [WSConnection.Event] { events.withLock { $0 } }
        var frames: [ServerFrame] {
            all.compactMap { if case .frame(let frame) = $0 { return frame } else { return nil } }
        }
        func count(_ event: WSConnection.Event) -> Int { all.filter { $0 == event }.count }

        func append(_ event: WSConnection.Event) { events.withLock { $0.append(event) } }
    }

    static var sessionsFrame: [String: Any] {
        [
            "t": "sessions",
            "list": [["id": "s1", "order": 0, "cwd": "/Users/me", "command": "", "state": "idle", "exit": NSNull(),
                      "integrated": true, "memo": "", "agent": "", "agent_state": "none", "brand_new_field": [1, 2]]],
        ]
    }

    // Scenario: WebSocket upgrade
    @Test func connectsWithBearerAndWithoutOrigin() async throws {
        let server = try MockWebSocketServer(onConnect: { server, connection in
            server.send(json: Self.sessionsFrame, on: connection)
        })
        try await server.start()
        defer { server.stop() }

        let log = EventLog()
        let connection = WSConnection(port: server.port, token: token)
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }

        #expect(await waitUntil { log.frames.count == 1 })
        #expect(log.all.first == .connected)
        guard case .sessions(let list)? = log.frames.first else {
            Issue.record("expected a sessions frame")
            return
        }
        #expect(list.map(\.id) == ["s1"])

        let headers = server.handshakeHeaders.first ?? [:]
        #expect(headers["authorization"] == "Bearer \(token)")
        #expect(headers["origin"] == nil)
        #expect(headers.keys.contains("origin") == false)
    }

    @Test func framesAreSentInOrderAndDroppedWhileDisconnected() async throws {
        let server = try MockWebSocketServer()
        try await server.start()
        defer { server.stop() }

        let connection = WSConnection(port: server.port, token: token)
        // つながる前は積めない。
        #expect(connection.enqueue(.attach(sid: "early")) == false)

        let log = EventLog()
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }
        #expect(await waitUntil { log.count(.connected) == 1 })

        #expect(connection.enqueue(.attach(sid: "s1")))
        #expect(connection.enqueue(.input(sid: "s1", bytes: Array("ls\r".utf8))))
        #expect(connection.enqueue(.resize(sid: "s1", cols: 120, rows: 40)))
        #expect(await waitUntil { server.received.count == 3 })
        #expect(server.received == [
            #"{"binary":true,"sid":"s1","t":"attach"}"#,
            #"{"data":"bHMN","sid":"s1","t":"input"}"#,
            #"{"cols":120,"rows":40,"sid":"s1","t":"resize"}"#,
        ])
    }

    // Unknown frames do not disconnect.
    @Test func unknownFramesAreIgnoredWithoutDisconnecting() async throws {
        let server = try MockWebSocketServer(onConnect: { server, connection in
            server.send(#"{"t":"hologram","sid":"s1","payload":{"x":1}}"#, on: connection)
            server.send("not json at all", on: connection)
            server.send(#"{"t":"replay","sid":7}"#, on: connection)
            server.send(json: Self.sessionsFrame, on: connection)
            server.send(json: ["t": "output", "sid": "s1", "data": Data("hi".utf8).base64EncodedString(), "extra": true], on: connection)
        })
        try await server.start()
        defer { server.stop() }

        let log = EventLog()
        let connection = WSConnection(port: server.port, token: token)
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }

        #expect(await waitUntil { log.frames.count == 2 })
        #expect(log.frames.last == .output(sid: "s1", data: Array("hi".utf8)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(log.count(.disconnected) == 0)
        #expect(server.connectCount == 1)
    }

    // Scenario: Backoff growth
    @Test func backoffDelaysGrowAndCap() {
        let delays = (0..<8).map { WSConnection.backoffDelay(attempt: $0) }
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5), .seconds(5), .seconds(5)])
    }

    @Test func failedConnectionsBackOff() async throws {
        let port = try await unusedLoopbackPort()
        let delays = OSAllocatedUnfairLock(initialState: [Duration]())
        let connection = WSConnection(port: port, token: token, sleep: { delay in
            delays.withLock { $0.append(delay) }
            try await Task.sleep(for: .milliseconds(1))
        })
        await connection.start { _ in }
        #expect(await waitUntil { delays.withLock { $0.count } >= 6 })
        await connection.stop()
        #expect(Array(delays.withLock { $0 }.prefix(6)) == [
            .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5),
        ])
    }

    // Scenario: Daemon restart（つながったら待ち時間を 0.5 秒に戻す）
    @Test func backoffResetsAfterASuccessfulConnection() async throws {
        let server = try MockWebSocketServer(onConnect: { server, connection in
            server.send(json: Self.sessionsFrame, on: connection)
        })
        try await server.start()
        defer { server.stop() }

        let delays = OSAllocatedUnfairLock(initialState: [Duration]())
        let log = EventLog()
        let connection = WSConnection(port: server.port, token: token, sleep: { delay in
            delays.withLock { $0.append(delay) }
            try await Task.sleep(for: .milliseconds(20))
        })
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }

        #expect(await waitUntil { log.count(.connected) == 1 })
        server.dropAll()
        #expect(await waitUntil { log.count(.connected) == 2 })
        server.dropAll()
        #expect(await waitUntil { log.count(.connected) == 3 })
        #expect(log.count(.disconnected) == 2)
        #expect(delays.withLock { $0 } == [.milliseconds(500), .milliseconds(500)])
        // 切断中は送れない。
        #expect(server.connectCount == 3)
    }

    // 最初の接続に失敗したときも、つながっていないことを知らせる（再試行のたびには知らせない）。
    // 知らせないと、起動した直後にデーモンへつながらないとき、空のウィンドウのまま何も出ない。
    @Test func aFailedFirstConnectionIsReportedOnce() async throws {
        let server = try MockWebSocketServer()
        server.rejectionStatus = 503
        try await server.start()
        defer { server.stop() }

        let log = EventLog()
        let connection = WSConnection(port: server.port, token: token, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }

        #expect(await waitUntil { server.handshakeHeaders.count >= 3 })
        #expect(log.all == [.disconnected])
        server.rejectionStatus = nil
        #expect(await waitUntil { log.count(.connected) == 1 })
        #expect(log.all == [.disconnected, .connected])
    }

    // デーモンがトークンを拒否したら（config.json が作り直されたなど）、拒否されたことを 1 回だけ知らせる。
    // 再試行しても同じトークンでは通らないので、利用者に config.json を読み直してもらう必要がある。
    @Test(arguments: [401, 403])
    func aRejectedConnectionIsReported(status: Int) async throws {
        let server = try MockWebSocketServer()
        server.rejectionStatus = status
        try await server.start()
        defer { server.stop() }

        let log = EventLog()
        let connection = WSConnection(port: server.port, token: token, sleep: { _ in try await Task.sleep(for: .milliseconds(10)) })
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }

        #expect(await waitUntil { server.handshakeHeaders.count >= 3 })
        #expect(log.all == [.disconnected, .rejected(status: status)])
    }

    // Scenario: Idle connection stays open（デーモンの ping に pong を返す）
    @Test func answersServerPings() async throws {
        let server = try MockWebSocketServer()
        try await server.start()
        defer { server.stop() }

        let log = EventLog()
        let connection = WSConnection(port: server.port, token: token)
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }
        #expect(await waitUntil { log.count(.connected) == 1 })
        #expect(await server.pingLatest())
    }
}
