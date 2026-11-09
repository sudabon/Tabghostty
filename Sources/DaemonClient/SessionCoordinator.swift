import Foundation
import os
import TerminalCore

/// セッションを作る・再起動する REST の操作（テストで差し替える）。
public protocol SessionAPI: Sendable {
    func createSession(cwd: String?) async throws -> SessionInfo
    func restartSession(id: String) async throws -> SessionInfo
}

extension RESTClient: SessionAPI {}

/// 表示中のセッションの `TerminalController`。受信ループから同期的に引けるよう、ロックで守る。
final class ControllerRegistry: Sendable {
    private let controllers = OSAllocatedUnfairLock(initialState: [String: TerminalController]())

    subscript(sid: String) -> TerminalController? {
        controllers.withLock { $0[sid] }
    }

    var all: [TerminalController] {
        controllers.withLock { Array($0.values) }
    }

    func insert(_ controller: TerminalController) {
        controllers.withLock { $0[controller.sid] = controller }
    }

    func remove(_ sid: String) {
        _ = controllers.withLock { $0.removeValue(forKey: sid) }
    }
}

/// WebSocket・セッション一覧・表示中の端末をつなぐ。
///
/// - `replay` / `output` / `attach_overflow` は、受信ループから直接、表示中のセッションの `TerminalController` に渡す。
///   表示していないセッションの output は捨てる（detach が無いので届き続ける。design D3）。
/// - `sessions` / `state` / `agent_state` は `SessionStore` に反映し、アクティブセッションが変わったら
///   そのセッションのコントローラを作って attach する。
/// - 再接続したら、表示中のコントローラをリセットして attach し直す（spec: terminal-session「Re-attach after reconnect」）。
/// - 起動後最初の `sessions` で、使えるセッションを用意する（spec: tab-operations「Bootstrap a usable session on startup」）。
@MainActor
public final class SessionCoordinator {
    public typealias ControllerFactory = @MainActor (_ sid: String, _ sink: any TerminalFrameSink) throws -> TerminalController

    public let store: SessionStore
    public let connection: WSConnection
    private let api: any SessionAPI
    private let makeController: ControllerFactory
    private nonisolated let registry = ControllerRegistry()

    /// アクティブセッションの端末。
    public private(set) var activeController: TerminalController?
    public private(set) var isConnected = false
    /// ビューのグリッドサイズ。新しく作るコントローラに最初から設定する。
    public var viewGrid: TerminalController.GridSize? {
        didSet {
            guard let viewGrid, viewGrid != oldValue, let controller = activeController else { return }
            Task { await controller.setViewGrid(viewGrid) }
        }
    }

    private var didBootstrap = false

    /// アクティブセッションの端末が変わった。
    public var onActiveControllerChange: ((TerminalController?) -> Void)?
    /// 一時的に知らせるメッセージ（error フレーム、失敗したリクエスト）。
    public var onTransientMessage: ((String) -> Void)?
    /// 接続状態が変わった。
    public var onConnectionChange: ((Bool) -> Void)?

    public init(
        connection: WSConnection,
        api: any SessionAPI,
        store: SessionStore = SessionStore(),
        makeController: @escaping ControllerFactory
    ) {
        self.connection = connection
        self.api = api
        self.store = store
        self.makeController = makeController
    }

    /// 接続を始める。
    public func start() async {
        await connection.start { [weak self] event in
            await self?.handle(event)
        }
    }

    /// 接続をやめる（デーモンとセッションはそのまま残る）。
    public func stop() async {
        await connection.stop()
    }

    // MARK: - 受信

    nonisolated func handle(_ event: WSConnection.Event) async {
        switch event {
        case .connected:
            // 表示中のセッションをリセットして attach し直す。サイズは live になってから送る。
            for controller in registry.all {
                await controller.attach()
            }
            await MainActor.run { self.setConnected(true) }
        case .disconnected:
            for controller in registry.all {
                await controller.connectionLost()
            }
            await MainActor.run { self.setConnected(false) }
        case .frame(let frame):
            await route(frame)
        }
    }

    private nonisolated func route(_ frame: ServerFrame) async {
        switch frame {
        case .replay(let sid, let data, let done):
            await registry[sid]?.receiveReplay(data, done: done)
        case .output(let sid, let data):
            await registry[sid]?.receiveOutput(data)
        case .error(let sid, let code, let message):
            if code == "attach_overflow", let sid, let controller = registry[sid] {
                await controller.handleAttachOverflow()
            }
            await MainActor.run { self.onTransientMessage?(message) }
        case .sessions, .state, .agentState:
            // 新しく表示するセッションは、次のフレームを処理する前に attach しておく。
            let started = await MainActor.run { self.apply(frame) }
            if let started {
                await attach(started)
            }
        case .notify, .unknown:
            // 通知は Phase 4。
            break
        }
    }

    // MARK: - セッション一覧とアクティブセッション

    /// 一覧を反映し、アクティブセッションのコントローラを作ったらそれを返す（呼び出し側で attach する）。
    private func apply(_ frame: ServerFrame) -> TerminalController? {
        store.apply(frame)
        guard case .sessions = frame else { return nil }
        let started = updateActiveController()
        bootstrapIfNeeded()
        return started
    }

    /// アクティブセッションに合わせてコントローラを作り直す。新しく作ったらそれを返す。
    @discardableResult
    private func updateActiveController() -> TerminalController? {
        let activeID = store.activeSession?.id
        guard activeController?.sid != activeID else { return nil }

        if let previous = activeController {
            registry.remove(previous.sid)
        }
        activeController = nil

        var started: TerminalController?
        if let activeID {
            do {
                let controller = try makeController(activeID, connection)
                registry.insert(controller)
                activeController = controller
                started = controller
            } catch {
                onTransientMessage?("Failed to create a terminal for the session: \(error.localizedDescription)")
            }
        }
        onActiveControllerChange?(activeController)
        return started
    }

    private nonisolated func attach(_ controller: TerminalController) async {
        if let grid = await MainActor.run(body: { self.viewGrid }) {
            await controller.setViewGrid(grid)
        }
        await controller.attach()
    }

    /// 指定したセッションをアクティブにする。
    public func activate(_ id: String) {
        store.activate(id)
        if let started = updateActiveController() {
            Task { await attach(started) }
        }
    }

    // MARK: - 起動時のセッション確保

    private func bootstrapIfNeeded() {
        guard !didBootstrap, let action = store.bootstrapAction() else { return }
        // 起動後に 1 回だけ。再接続では行わない。
        didBootstrap = true
        switch action {
        case .useExisting:
            return
        case .create:
            Task { await self.runBootstrap { try await self.api.createSession(cwd: nil) } }
        case .restart(let id):
            Task { await self.runBootstrap { try await self.api.restartSession(id: id) } }
        }
    }

    private func runBootstrap(_ request: @escaping @Sendable () async throws -> SessionInfo) async {
        do {
            let session = try await request()
            activate(session.id)
        } catch {
            onTransientMessage?(error.localizedDescription)
        }
    }

    private func setConnected(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
        onConnectionChange?(connected)
    }
}
