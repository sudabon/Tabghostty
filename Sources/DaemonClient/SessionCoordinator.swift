import Foundation
import os
import TerminalCore

/// タブの操作に使う REST（テストで差し替える）。
public protocol SessionAPI: Sendable {
    func createSession(cwd: String?) async throws -> SessionInfo
    func restartSession(id: String) async throws -> SessionInfo
    func duplicateSession(id: String) async throws -> SessionInfo
    func deleteSession(id: String) async throws
    @discardableResult
    func updateSessionMemo(id: String, memo: String) async throws -> SessionInfo
    @discardableResult
    func setSessionNotificationsMuted(id: String, muted: Bool) async throws -> SessionInfo
    func reorderSessions(ids: [String]) async throws
}

extension RESTClient: SessionAPI {}

/// 一覧にあるセッションの `TerminalController`。受信ループから同期的に引けるよう、ロックで守る。
final class ControllerRegistry: Sendable {
    private let controllers = OSAllocatedUnfairLock(initialState: [String: TerminalController]())

    subscript(sid: String) -> TerminalController? {
        controllers.withLock { $0[sid] }
    }

    var all: [TerminalController] {
        controllers.withLock { Array($0.values) }
    }

    var sids: Set<String> {
        controllers.withLock { Set($0.keys) }
    }

    func insert(_ controller: TerminalController) {
        controllers.withLock { $0[controller.sid] = controller }
    }

    func remove(_ sid: String) {
        _ = controllers.withLock { $0.removeValue(forKey: sid) }
    }
}

/// WebSocket・セッション一覧・各セッションの端末をつなぐ。
///
/// - 一覧にあるセッションはすべて attach し、裏のタブも端末を更新し続ける（spec: terminal-session
///   「All sessions stay attached」、phase3 design D1）。タブを切り替えても replay はしない。
/// - `replay` / `output` / `attach_overflow` は、受信ループから直接、そのセッションの `TerminalController` に渡す。
/// - `sessions` / `state` / `agent_state` / `notify` は `SessionStore` に反映する。`sessions` を受け取ったら、
///   一覧との差分でコントローラを作って attach し、一覧から消えたセッションのコントローラは手放す。
/// - グリッドのサイズはウィンドウで 1 つ。変わったら全セッションに反映する（spec: terminal-session
///   「All sessions share the window's grid size」）。
/// - 再接続したら、次の `sessions` で一覧に残っているセッションをリセットして attach し直す
///   （spec: terminal-session「Re-attach after reconnect」）。
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
    /// ウィンドウの端末領域のグリッドサイズ。全セッションの端末に反映する。
    public var viewGrid: TerminalController.GridSize? {
        didSet {
            guard let viewGrid, viewGrid != oldValue else { return }
            let controllers = registry.all
            Task {
                for controller in controllers {
                    await controller.setViewGrid(viewGrid)
                }
            }
        }
    }

    private var didBootstrap = false
    /// 接続し直したので、次の `sessions` で一覧に残っているセッションを attach し直す。
    private var needsReattach = false

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

    /// セッションの端末（一覧にあるものだけ）。
    public func controller(for sid: String) -> TerminalController? {
        registry[sid]
    }

    /// 端末を持っているセッションの ID。
    public var attachedSessionIDs: Set<String> {
        registry.sids
    }

    /// 一覧にあるすべてのセッションの端末（設定の変更を反映するのに使う）。
    public var allControllers: [TerminalController] {
        registry.all
    }

    // MARK: - 受信

    nonisolated func handle(_ event: WSConnection.Event) async {
        switch event {
        case .connected:
            // デーモンは接続の直後に `sessions` を送る。一覧に残っているセッションだけを、そのときに attach し直す
            // （デーモンが再起動して消えたセッションに attach しない）。
            await MainActor.run {
                self.needsReattach = true
                self.setConnected(true)
            }
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
            // 書き込みは待たない。大量の出力を書き込んでいるセッションがあっても、次のフレーム（ほかのセッションの
            // エコーなど）をすぐに読む。セッションごとの順序は、そのセッションの端末が保つ（phase5 design D2）。
            registry[sid]?.enqueueReplay(data, done: done)
        case .output(let sid, let data):
            registry[sid]?.enqueueOutput(data)
        case .error(let sid, let code, let message):
            if code == "attach_overflow", let sid, let controller = registry[sid] {
                await controller.handleAttachOverflow()
            }
            await MainActor.run { self.onTransientMessage?(message) }
        case .sessions, .state, .agentState, .notify:
            // 新しく attach するセッションは、次のフレームを処理する前に attach しておく。
            let work = await MainActor.run { self.apply(frame) }
            for controller in work.attach {
                await attach(controller)
            }
            if let activated = work.activated {
                await activated.resendViewSize()
            }
        case .unknown:
            break
        }
    }

    // MARK: - セッション一覧とアクティブセッション

    /// フレームを反映したあとにすること。
    private struct ListWork {
        /// attach する端末。
        var attach: [TerminalController] = []
        /// 新しくアクティブになった、既にある端末（サイズを送り直す）。
        var activated: TerminalController?
    }

    private func apply(_ frame: ServerFrame) -> ListWork {
        store.apply(frame)
        guard case .sessions = frame else { return ListWork() }
        var work = ListWork()
        work.attach = syncControllers()
        if let activated = updateActiveController(), !work.attach.contains(where: { $0 === activated }) {
            work.activated = activated
        }
        bootstrapIfNeeded()
        return work
    }

    /// 一覧との差分で端末を作り、消えたセッションの端末を手放す。attach する端末を返す。
    private func syncControllers() -> [TerminalController] {
        let ids = store.sessions.map(\.id)
        let listed = Set(ids)
        for sid in registry.sids where !listed.contains(sid) {
            registry.remove(sid)
        }

        var attach: [TerminalController] = []
        if needsReattach {
            needsReattach = false
            attach = ids.compactMap { registry[$0] }
        }
        for sid in ids where registry[sid] == nil {
            do {
                let controller = try makeController(sid, connection)
                registry.insert(controller)
                attach.append(controller)
            } catch {
                onTransientMessage?("Failed to create a terminal for the session: \(error.localizedDescription)")
            }
        }
        return attach
    }

    /// アクティブセッションの端末に切り替える。切り替えたらその端末を返す。
    @discardableResult
    private func updateActiveController() -> TerminalController? {
        let next = store.activeSessionID.flatMap { registry[$0] }
        guard next !== activeController else { return nil }
        activeController = next
        onActiveControllerChange?(next)
        return next
    }

    private nonisolated func attach(_ controller: TerminalController) async {
        if let grid = await MainActor.run(body: { self.viewGrid }) {
            await controller.setViewGrid(grid)
        }
        await controller.attach()
    }

    /// 指定したセッションをアクティブにする。端末が既にあれば replay せずにそのまま表示し、
    /// ほかのクライアントが PTY のサイズを変えているかもしれないので、グリッドサイズを送り直す。
    /// まだ一覧に無いセッション（作った直後）は、一覧に入ったときにアクティブになる。
    public func activate(_ id: String) {
        store.activate(id)
        if let activated = updateActiveController() {
            Task { await activated.resendViewSize() }
        }
    }

    // MARK: - タブの操作（spec: tab-operations）

    /// 新しいセッションをホームディレクトリで作り、アクティブにする。一覧はデーモンの `sessions` で変わる。
    public func createSession() async {
        await runActivating { try await self.api.createSession(cwd: nil) }
    }

    /// セッションを複製し、できたセッションをアクティブにする。
    public func duplicateSession(_ id: String) async {
        await runActivating { try await self.api.duplicateSession(id: id) }
    }

    /// 終了済みのセッションを再起動し、できたセッションをアクティブにする。終了していなければ何もしない。
    public func restartSession(_ id: String) async {
        guard store.sessions.first(where: { $0.id == id })?.isExited == true else { return }
        await runActivating { try await self.api.restartSession(id: id) }
    }

    /// セッションを閉じる（確認は呼び出し側で行う）。アクティブなら、一覧が変わったときに選び直す。
    public func closeSession(_ id: String) async {
        do {
            try await api.deleteSession(id: id)
        } catch {
            onTransientMessage?(error.localizedDescription)
        }
    }

    /// メモを保存する（失敗したら投げる。メモの編集シートを開いたままにするため）。
    public func updateMemo(_ id: String, memo: String) async throws {
        do {
            try await api.updateSessionMemo(id: id, memo: memo)
        } catch {
            onTransientMessage?(error.localizedDescription)
            throw error
        }
    }

    /// 通知のミュートを切り替える。すぐにこのクライアントの表示を変え、失敗したら戻してメッセージを出す。
    public func toggleNotificationsMuted(_ id: String) async {
        guard let current = store.sessions.first(where: { $0.id == id }) else { return }
        let muted = !current.notificationsMuted
        store.setNotificationsMuted(id, muted)
        do {
            try await api.setSessionNotificationsMuted(id: id, muted: muted)
        } catch {
            store.setNotificationsMuted(id, !muted)
            onTransientMessage?(error.localizedDescription)
        }
    }

    /// 並べ替えた順序を保存する。ローカルの並びは変えず、デーモンの `sessions` を待つ。
    public func reorderSessions(_ ids: [String]) async {
        do {
            try await api.reorderSessions(ids: ids)
        } catch {
            onTransientMessage?(error.localizedDescription)
        }
    }

    private func runActivating(_ request: @escaping @Sendable () async throws -> SessionInfo) async {
        do {
            let session = try await request()
            activate(session.id)
        } catch {
            onTransientMessage?(error.localizedDescription)
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
            Task { await self.runActivating { try await self.api.createSession(cwd: nil) } }
        case .restart(let id):
            Task { await self.runActivating { try await self.api.restartSession(id: id) } }
        }
    }

    private func setConnected(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
        onConnectionChange?(connected)
    }
}
