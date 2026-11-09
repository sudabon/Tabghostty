import Foundation
import Testing
import TerminalCore
@testable import DaemonClient

/// spec: daemon-connection「Binary output frames」— バイナリのメッセージの形式（phase6 design D3 の案）と attach の宣言。
@Suite struct BinaryFrameDecodingTests {
    private func decode(_ data: Data) -> ServerFrame? { ServerFrame.decode(binaryMessage: data) }

    private func message(_ kind: UInt8, _ sid: String, _ bytes: [UInt8]) -> Data {
        MockDaemon.binary(kind: kind, sid, bytes)
    }

    @Test func outputAndReplayKinds() {
        let hi = Array("hi".utf8)
        #expect(decode(message(0x01, "s1", hi)) == .output(sid: "s1", data: hi))
        #expect(decode(message(0x02, "s1", hi)) == .replay(sid: "s1", data: hi, done: false))
        #expect(decode(message(0x03, "s1", hi)) == .replay(sid: "s1", data: hi, done: true))
        // replay の最後のチャンクは空でもよい。
        #expect(decode(message(0x03, "s1", [])) == .replay(sid: "s1", data: [], done: true))
    }

    // 同梱のデーモンのエンコーダと同じバイト列を読めること。基準のバイト列は Go のテスト
    // （daemon/internal/server/ws_binary_test.go の TestBinaryFramesMatchTheSharedVectors）と同じファイルから読む。
    @Test func sharedVectorsFromTheBundledDaemon() throws {
        struct Vector: Decodable {
            let name: String
            let kind: UInt8
            let sid: String
            let payload_hex: String
            let frame_hex: String
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/internal/server/testdata/binary_frames.json")
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        #expect(Set(vectors.map(\.kind)) == [0x01, 0x02, 0x03])
        for vector in vectors {
            let payload = try #require(Self.bytes(hex: vector.payload_hex), "\(vector.name)")
            let frame = try #require(Self.bytes(hex: vector.frame_hex), "\(vector.name)")
            let expected: ServerFrame? = switch vector.kind {
            case 0x01: .output(sid: vector.sid, data: payload)
            case 0x02: .replay(sid: vector.sid, data: payload, done: false)
            case 0x03: .replay(sid: vector.sid, data: payload, done: true)
            default: nil
            }
            #expect(decode(Data(frame)) == expected, "\(vector.name)")
        }
    }

    private static func bytes(hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    @Test func payloadBytesArePassedThroughUnchanged() {
        let sid = "123e4567-e89b-12d3-a456-426614174000"
        // UTF-8 として正しくないバイトや NUL も、そのまま端末に渡す。
        let payload: [UInt8] = [0x1B, 0x5B, 0xFF, 0x00, 0xE6, 0x97]
        #expect(decode(message(0x01, sid, payload)) == .output(sid: sid, data: payload))
    }

    @Test func dataSlicesWithAnOffsetAreRead() {
        let framed = Data([0xAA, 0xBB]) + message(0x01, "s1", Array("x".utf8))
        let slice = framed.dropFirst(2)
        #expect(slice.startIndex == 2)
        #expect(decode(slice) == .output(sid: "s1", data: Array("x".utf8)))
    }

    // 形に合わないメッセージは無視する（接続は切らない）。
    @Test func malformedMessagesAreIgnored() {
        #expect(decode(Data()) == nil)
        #expect(decode(Data([0x01])) == nil)
        // sid が空。
        #expect(decode(Data([0x01, 0x00, 0x41])) == nil)
        // sid の長さがメッセージより長い。
        #expect(decode(Data([0x01, 0x05, 0x73, 0x31])) == nil)
        // sid が ASCII でない。
        #expect(decode(Data([0x01, 0x02, 0xC3, 0xA9, 0x41])) == nil)
        // 未知の種類で、JSON でもない。
        #expect(decode(Data([0x04, 0x01, 0x73])) == nil)
        #expect(decode(Data([0x00, 0x01, 0x73])) == nil)
        #expect(decode(Data([0x7B, 0x01])) == nil)
    }

    // バイナリで届いた JSON は、これまでどおり JSON として読む。
    @Test func jsonInABinaryMessageIsStillRead() {
        let json = Data(#"{"t":"output","sid":"s1","data":"aGk="}"#.utf8)
        #expect(decode(json) == .output(sid: "s1", data: Array("hi".utf8)))
    }

    @Test func attachDeclaresBinaryAndOtherFramesDoNot() {
        let text = { (frame: TerminalOutgoingFrame) in String(decoding: frame.encodedJSON(), as: UTF8.self) }
        #expect(text(.attach(sid: "s1")) == #"{"binary":true,"sid":"s1","t":"attach"}"#)
        #expect(text(.input(sid: "s1", bytes: Array("ls\r".utf8))) == #"{"data":"bHMN","sid":"s1","t":"input"}"#)
        #expect(text(.resize(sid: "s1", cols: 80, rows: 24)) == #"{"cols":80,"rows":24,"sid":"s1","t":"resize"}"#)
    }
}

/// `WSConnection` がテキストとバイナリのメッセージを、届いた順にフレームとして渡す。
@Suite struct WSConnectionBinaryTests {
    @Test func textAndBinaryMessagesAreDeliveredInOrder() async throws {
        let base64: @Sendable (String) -> String = { Data($0.utf8).base64EncodedString() }
        let server = try MockWebSocketServer(onConnect: { server, connection in
            server.send(json: ["t": "replay", "sid": "s1", "data": base64("a"), "done": false], on: connection)
            server.send(binary: MockDaemon.binary(kind: 0x02, "s1", Array("b".utf8)), on: connection)
            // 読めないバイナリは無視する。
            server.send(binary: Data([0x7F, 0x00]), on: connection)
            server.send(binary: MockDaemon.binary(kind: 0x03, "s1", Array("c".utf8)), on: connection)
            server.send(binary: MockDaemon.binary(kind: 0x01, "s1", Array("d".utf8)), on: connection)
            server.send(json: ["t": "output", "sid": "s1", "data": base64("e")], on: connection)
        })
        try await server.start()
        defer { server.stop() }

        let log = WSConnectionTests.EventLog()
        let connection = WSConnection(port: server.port, token: "token")
        await connection.start { log.append($0) }
        defer { Task { await connection.stop() } }

        #expect(await waitUntil { log.frames.count == 5 })
        #expect(log.frames == [
            .replay(sid: "s1", data: Array("a".utf8), done: false),
            .replay(sid: "s1", data: Array("b".utf8), done: false),
            .replay(sid: "s1", data: Array("c".utf8), done: true),
            .output(sid: "s1", data: Array("d".utf8)),
            .output(sid: "s1", data: Array("e".utf8)),
        ])
        #expect(log.count(.disconnected) == 0)
        #expect(server.connectCount == 1)
    }
}

/// モックのデーモンと `SessionCoordinator` で、JSON だけ・バイナリだけ・両方が混ざる場合に同じ画面になり、
/// replay を最後まで受け取ると live に移ることを確かめる（phase6 design D4）。
@MainActor
@Suite(.serialized) struct BinaryFrameSessionTests {
    enum Mode: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// 古いデーモン（`binary` を無視して JSON で送る）。
        case json
        /// バイナリフレームに対応したデーモン。
        case binary
        /// replay は JSON、output はバイナリ。
        case mixed

        var testDescription: String { rawValue }
    }

    private nonisolated static let sid = "s1"
    private let grid = TerminalController.GridSize(cols: 80, rows: 10, cellWidthPx: 16, cellHeightPx: 34)

    /// replay のチャンク。UTF-8 の文字とエスケープシーケンスの途中で区切る。
    private nonisolated static let replayChunks: [[UInt8]] = [
        Array("\u{1b}[1mbold\u{1b}[0m ".utf8) + [0xE6], // 「日」の 1 バイト目まで
        [0x97, 0xA5] + Array("本語\r\n\u{1b}[3".utf8), // SGR の途中まで
        Array("1mred\u{1b}[0m".utf8),
    ]
    /// replay の後の output。「✓」（E2 9C 93）の途中で区切る。
    private nonisolated static let outputChunks: [[UInt8]] = [
        Array("\r\nlive ".utf8) + [0xE2, 0x9C],
        [0x93] + Array(" done".utf8),
    ]
    private nonisolated static let expectedScreen = "bold 日本語\nred\nlive ✓ done"

    private nonisolated static func jsonReplay(_ bytes: [UInt8], done: Bool) -> MockDaemon.Message {
        .json(["t": "replay", "sid": sid, "data": Data(bytes).base64EncodedString(), "done": done])
    }

    private nonisolated static func jsonOutput(_ bytes: [UInt8]) -> MockDaemon.Message {
        .json(["t": "output", "sid": sid, "data": Data(bytes).base64EncodedString()])
    }

    private nonisolated static func messages(for mode: Mode) -> [MockDaemon.Message] {
        let lastReplay = replayChunks.count - 1
        let replays: [MockDaemon.Message] = replayChunks.enumerated().map { index, chunk in
            switch mode {
            case .json, .mixed: jsonReplay(chunk, done: index == lastReplay)
            case .binary: .binary(MockDaemon.binary(kind: index == lastReplay ? 0x03 : 0x02, sid, chunk))
            }
        }
        let outputs: [MockDaemon.Message] = outputChunks.map { chunk in
            switch mode {
            case .json: jsonOutput(chunk)
            case .binary, .mixed: .binary(MockDaemon.binary(kind: 0x01, sid, chunk))
            }
        }
        return replays + outputs
    }

    private func makeCoordinator(port: Int) -> SessionCoordinator {
        let connection = WSConnection(port: port, token: "token", sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let coordinator = SessionCoordinator(connection: connection, api: MockSessionAPI()) { sid, sink in
            try TerminalController(sid: sid, maxScrollback: 1000, colors: nil, sink: sink)
        }
        coordinator.viewGrid = grid
        return coordinator
    }

    private func screen(_ coordinator: SessionCoordinator) async -> String {
        await coordinator.activeController?.plainText() ?? ""
    }

    // Scenario: Daemon with binary support / Older daemon
    @Test(arguments: Mode.allCases)
    func everyModeShowsTheSameScreenAndGoesLive(mode: Mode) async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session(Self.sid)]) { _, _ in Self.messages(for: mode) }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { await self.screen(coordinator) == Self.expectedScreen })
        #expect(await screen(coordinator) == Self.expectedScreen)
        #expect(await coordinator.activeController?.phase == .live)
        // どのデーモンに対しても、attach で binary を宣言する。
        let attach = daemon.server.receivedObjects.first { $0["t"] as? String == "attach" }
        #expect(attach?["binary"] as? Bool == true)
    }

    // Scenario: Replay completion in binary
    @Test func binaryReplayGoesLiveOnlyAtTheLastChunk() async throws {
        let daemon = try MockDaemon(sessions: [MockDaemon.session(Self.sid)]) { sid, _ in
            [.binary(MockDaemon.binary(kind: 0x02, sid, Array("partial".utf8)))]
        }
        try await daemon.start()
        defer { daemon.stop() }
        let coordinator = makeCoordinator(port: daemon.server.port)
        await coordinator.start()
        defer { Task { await coordinator.stop() } }

        #expect(await waitUntil { await self.screen(coordinator) == "partial" })
        // 最後のチャンク（0x03）が来るまでは replay のまま。
        try await Task.sleep(for: .milliseconds(100))
        #expect(await coordinator.activeController?.phase == .replaying)

        daemon.server.sendToLatest(binary: MockDaemon.binary(kind: 0x03, Self.sid, Array(" rest".utf8)))
        #expect(await waitUntil { await coordinator.activeController?.phase == .live })
        #expect(await screen(coordinator) == "partial rest")

        daemon.server.sendToLatest(binary: MockDaemon.binary(kind: 0x01, Self.sid, Array("\r\nlive".utf8)))
        #expect(await waitUntil { await self.screen(coordinator) == "partial rest\nlive" })
    }
}
