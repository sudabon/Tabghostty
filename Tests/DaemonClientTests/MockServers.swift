import Foundation
import Network
import os

/// 条件が満たされるまで待つ（満たされなければ false）。
func waitUntil(
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(10),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return await condition()
}

/// 127.0.0.1 の空いているポートで待ち受ける `NWListener` を作り、待ち受けを始めるまで待つ。
private func startListener(_ listener: NWListener, queue: DispatchQueue) async throws -> Int {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
            case .failed(let error):
                if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }
    guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
    return Int(port)
}

private func loopbackParameters(_ parameters: NWParameters) -> NWParameters {
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    parameters.allowLocalEndpointReuse = true
    return parameters
}

/// 何も待ち受けていないポートを 1 つ探す（一度待ち受けて、すぐ閉じる）。
func unusedLoopbackPort() async throws -> Int {
    let listener = try NWListener(using: loopbackParameters(.tcp))
    listener.newConnectionHandler = { $0.cancel() }
    let port = try await startListener(listener, queue: DispatchQueue(label: "unused-port"))
    listener.cancel()
    try await Task.sleep(for: .milliseconds(50))
    return port
}

// MARK: - HTTP

/// 1 リクエストごとに決まった応答を返す HTTP サーバー。受け取ったリクエストを記録する。
final class MockHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// ヘッダ名は小文字にしてある。
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var reason: String
        var headers: [(String, String)]
        var body: Data

        static func json(_ status: Int, _ body: String) -> Response {
            Response(status: status, reason: "OK", headers: [("Content-Type", "application/json")], body: Data(body.utf8))
        }

        static func text(_ status: Int, _ reason: String, _ body: String, headers: [(String, String)] = []) -> Response {
            Response(status: status, reason: reason, headers: headers, body: Data(body.utf8))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockHTTPServer")
    private let state = OSAllocatedUnfairLock(initialState: [Request]())
    private let responder: @Sendable (Request) -> Response
    private(set) var port = 0

    var requests: [Request] { state.withLock { $0 } }

    init(responder: @escaping @Sendable (Request) -> Response) throws {
        self.responder = responder
        listener = try NWListener(using: loopbackParameters(.tcp))
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        port = try await startListener(listener, queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.state.withLock { $0.append(request) }
                self.respond(connection, self.responder(request))
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.read(connection, buffer: buffer)
        }
    }

    private func respond(_ connection: NWConnection, _ response: Response) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func parse(_ buffer: Data) -> Request? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[separator.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body.prefix(length)))
    }
}

// MARK: - WebSocket

/// デーモンの `/api/ws` を真似る WebSocket サーバー。
final class MockWebSocketServer: @unchecked Sendable {
    struct State {
        var handshakeHeaders: [[String: String]] = []
        var received: [String] = []
        var connections: [NWConnection] = []
        var connectCount = 0
        /// nil でなければ、接続要求をこの HTTP ステータスで断る（デーモンがトークンを拒否したときなど）。
        var rejectionStatus: Int?
    }

    /// WebSocket を話す本体（`NWProtocolWebSocket`）。
    private let listener: NWListener
    /// クライアントがつなぐ前段。接続要求のヘッダを記録して、本体へそのまま中継する
    /// （`NWProtocolWebSocket` はサーバー側に要求ヘッダを渡さないため）。
    private let frontListener: NWListener
    private var backendPort = 0
    private let queue = DispatchQueue(label: "MockWebSocketServer")
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// 接続ごとに、つながった直後に送るフレーム（デーモンの `sessions` など）。
    private let onConnect: @Sendable (MockWebSocketServer, NWConnection) -> Void
    /// クライアントからのテキストを受け取ったときの処理（`attach` に replay を返すなど）。
    private let onMessage: @Sendable (MockWebSocketServer, NWConnection, String) -> Void
    private(set) var port = 0

    var handshakeHeaders: [[String: String]] { state.withLock { $0.handshakeHeaders } }
    var received: [String] { state.withLock { $0.received } }
    var connectCount: Int { state.withLock { $0.connectCount } }

    /// 接続要求を断る HTTP ステータス（nil なら受け入れる）。
    var rejectionStatus: Int? {
        get { state.withLock { $0.rejectionStatus } }
        set { state.withLock { $0.rejectionStatus = newValue } }
    }

    /// 受け取ったフレームの `t` の値（順番どおり）。
    var receivedTypes: [String] {
        received.compactMap { text in
            (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["t"] as? String
        }
    }

    /// 受け取ったフレームを JSON のオブジェクトとして返す。
    var receivedObjects: [[String: Any]] {
        received.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    init(
        onConnect: @escaping @Sendable (MockWebSocketServer, NWConnection) -> Void = { _, _ in },
        onMessage: @escaping @Sendable (MockWebSocketServer, NWConnection, String) -> Void = { _, _, _ in }
    ) throws {
        self.onConnect = onConnect
        self.onMessage = onMessage
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: loopbackParameters(parameters))
        frontListener = try NWListener(using: loopbackParameters(.tcp))
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        backendPort = try await startListener(listener, queue: queue)
        frontListener.newConnectionHandler = { [weak self] connection in self?.relay(connection) }
        port = try await startListener(frontListener, queue: queue)
    }

    func stop() {
        frontListener.cancel()
        listener.cancel()
        dropAll()
    }

    /// つながっているすべての接続を切る（デーモンの再起動を真似る）。
    func dropAll() {
        let connections = state.withLock { state -> [NWConnection] in
            defer { state.connections.removeAll() }
            return state.connections
        }
        connections.forEach { $0.cancel() }
    }

    func clearReceived() {
        state.withLock { $0.received.removeAll() }
    }

    /// テキストのフレームを送る。
    func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// JSON のオブジェクトをフレームとして送る。
    func send(json object: [String: Any], on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        send(String(decoding: data, as: UTF8.self), on: connection)
    }

    /// バイナリのフレームを送る。
    func send(binary data: Data, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// 最新の接続にフレームを送る。
    func sendToLatest(json object: [String: Any]) {
        guard let connection = state.withLock({ $0.connections.last }) else { return }
        send(json: object, on: connection)
    }

    /// 最新の接続にバイナリのフレームを送る。
    func sendToLatest(binary data: Data) {
        guard let connection = state.withLock({ $0.connections.last }) else { return }
        send(binary: data, on: connection)
    }

    /// 最新の接続に ping を送り、pong が返ってきたら true。
    func pingLatest(timeout: Duration = .seconds(3)) async -> Bool {
        guard let connection = state.withLock({ $0.connections.last }) else { return false }
        let ponged = OSAllocatedUnfairLock(initialState: false)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { error in
            if error == nil { ponged.withLock { $0 = true } }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data("keepalive".utf8), contentContext: context, isComplete: true, completion: .idempotent)
        return await waitUntil(timeout: timeout) { ponged.withLock { $0 } }
    }

    // MARK: 前段の中継

    private func relay(_ client: NWConnection) {
        let backend = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(backendPort))!,
            using: .tcp
        )
        client.start(queue: queue)
        backend.start(queue: queue)
        readHandshake(client, backend: backend, buffer: Data())
    }

    private func readHandshake(_ client: NWConnection, backend: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
                let headers = Self.parseHeaders(head)
                let rejection = self.state.withLock { state -> Int? in
                    state.handshakeHeaders.append(headers)
                    return state.rejectionStatus
                }
                if let rejection {
                    let body = "unauthorized\n"
                    let response = "HTTP/1.1 \(rejection) Rejected\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    client.send(content: Data(response.utf8), completion: .contentProcessed { _ in client.cancel() })
                    backend.cancel()
                    return
                }
                backend.send(content: buffer, completion: .idempotent)
                self.pump(from: client, to: backend)
                self.pump(from: backend, to: client)
                return
            }
            if isComplete || error != nil {
                client.cancel()
                backend.cancel()
                return
            }
            self.readHandshake(client, backend: backend, buffer: buffer)
        }
    }

    private static func parseHeaders(_ head: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .idempotent)
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                return
            }
            self?.pump(from: source, to: destination)
        }
    }

    // MARK: WebSocket の本体

    private func accept(_ connection: NWConnection) {
        state.withLock {
            $0.connections.append(connection)
            $0.connectCount += 1
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.onConnect(self, connection)
            }
        }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                _ = error
                connection.cancel()
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                self.state.withLock { $0.received.append(text) }
                self.onMessage(self, connection, text)
            case .close?:
                connection.cancel()
                return
            default:
                break
            }
            self.receive(connection)
        }
    }
}
