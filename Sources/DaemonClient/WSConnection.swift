import Foundation
import os
import TerminalCore

/// デーモンとの WebSocket 接続（`ws://127.0.0.1:<port>/api/ws`）。
///
/// - 接続要求に `Authorization: Bearer` を付け、`Origin` は付けない（spec: daemon-connection「Authenticated requests」）。
/// - 受信ループは止めずに回し、デコードしたフレームを順にハンドラへ渡す（design D4）。
/// - 切断したら `min(500·2^n, 5000)` ms 待って再接続し、接続できたら n を 0 に戻す。
/// - 送信は `enqueue` で同期的にキューへ積む。切断中は積まずに捨てる（spec: terminal-input）。
public actor WSConnection: TerminalFrameSink {
    public enum Event: Sendable, Equatable {
        /// 接続できた（再接続を含む）。
        case connected
        /// 接続が切れた。この後、待ってから再接続する。
        case disconnected
        case frame(ServerFrame)
    }

    public typealias Handler = @Sendable (Event) async -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public nonisolated let port: Int
    private let token: String
    private let session: URLSession
    private let openWaiter: OpenWaiter
    private let sleep: Sleep

    /// 接続中の送信キュー。切断中は nil。
    private nonisolated let outbox = OSAllocatedUnfairLock<AsyncStream<String>.Continuation?>(initialState: nil)
    private var runTask: Task<Void, Never>?
    private var currentTask: URLSessionWebSocketTask?

    public init(port: Int, token: String, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.port = port
        self.token = token
        self.sleep = sleep
        let waiter = OpenWaiter()
        openWaiter = waiter
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: waiter, delegateQueue: nil)
    }

    deinit {
        // URLSession は delegate を強く持ち続けるので、使い終わったら明示的に無効にする（起動の再試行で作り直すとき）。
        session.invalidateAndCancel()
    }

    /// 再接続までの待ち時間（n 回続けて失敗した後）。0.5 s, 1 s, 2 s, 4 s, 5 s, 5 s, …
    public static func backoffDelay(attempt: Int) -> Duration {
        let exponent = min(max(attempt, 0), 16)
        return .milliseconds(min(500 * (1 << exponent), 5000))
    }

    /// 接続を始める。切断されても `stop()` まで再接続を続ける。
    public func start(handler: @escaping Handler) {
        guard runTask == nil else { return }
        runTask = Task { await self.run(handler: handler) }
    }

    /// 接続をやめる。
    public func stop() {
        runTask?.cancel()
        runTask = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil
        closeOutbox()
    }

    /// 送信キューに積む。切断中なら false。
    @discardableResult
    public nonisolated func enqueue(_ frame: TerminalOutgoingFrame) -> Bool {
        let text = String(decoding: frame.encodedJSON(), as: UTF8.self)
        return outbox.withLock { continuation in
            guard let continuation else { return false }
            if case .enqueued = continuation.yield(text) { return true }
            return false
        }
    }

    /// 接続要求（テストからも確かめる）。
    nonisolated func makeRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/api/ws")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - 接続ループ

    private func run(handler: @escaping Handler) async {
        var failures = 0
        while !Task.isCancelled {
            let task = session.webSocketTask(with: makeRequest())
            // replay のチャンク（base64 で約 33 KB）や大きな output を受けられるようにする。
            task.maximumMessageSize = 16 * 1024 * 1024
            currentTask = task
            let opened = await openWaiter.open(task)

            if opened && !Task.isCancelled {
                failures = 0
                let sender = openOutbox(for: task)
                await handler(.connected)
                await receiveLoop(task, handler: handler)
                closeOutbox()
                sender.cancel()
                task.cancel(with: .goingAway, reason: nil)
                await handler(.disconnected)
            } else {
                task.cancel()
            }
            currentTask = nil
            if Task.isCancelled { break }

            let delay = Self.backoffDelay(attempt: failures)
            failures += 1
            do {
                try await sleep(delay)
            } catch {
                break
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, handler: Handler) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                return
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            // JSON として読めないものや未知の種類は、接続を切らずに無視する。
            guard let frame = ServerFrame.decode(data) else { continue }
            if case .unknown = frame { continue }
            await handler(.frame(frame))
        }
    }

    private func openOutbox(for task: URLSessionWebSocketTask) -> Task<Void, Never> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        outbox.withLock { $0 = continuation }
        return Task {
            for await text in stream {
                do {
                    try await task.send(.string(text))
                } catch {
                    // 送れないなら接続は切れている。受信側が検出して再接続する。
                    return
                }
            }
        }
    }

    private func closeOutbox() {
        let continuation = outbox.withLock { continuation -> AsyncStream<String>.Continuation? in
            defer { continuation = nil }
            return continuation
        }
        continuation?.finish()
    }
}

/// WebSocket の接続が開いたか（または失敗したか）を待つための delegate。
private final class OpenWaiter: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private struct State {
        var results: [Int: Bool] = [:]
        var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func open(_ task: URLSessionWebSocketTask) async -> Bool {
        let id = task.taskIdentifier
        return await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool? in
                if let result = state.results.removeValue(forKey: id) { return result }
                state.waiters[id] = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
            task.resume()
        }
    }

    private func finish(_ task: URLSessionTask, opened: Bool) {
        let id = task.taskIdentifier
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            if let waiter = state.waiters.removeValue(forKey: id) { return waiter }
            // 待ち始める前に結果が出た。完了済みのタスクの結果は上書きしない。
            if state.results[id] == nil { state.results[id] = opened }
            return nil
        }
        waiter?.resume(returning: opened)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finish(webSocketTask, opened: true)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 開く前に完了した（接続できなかった）。開いた後の完了は、受信ループのエラーで検出する。
        finish(task, opened: false)
    }
}
