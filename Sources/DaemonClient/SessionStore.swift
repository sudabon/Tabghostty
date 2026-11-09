import Foundation

/// 起動時に、使えるセッションを用意するための操作（spec: tab-operations「Bootstrap a usable session on startup」）。
public enum SessionBootstrapAction: Equatable, Sendable {
    /// 今の一覧のまま使える（何もしなくてよい）。`Optional.none` と紛れないよう `none` という名前は避ける。
    case useExisting
    /// セッションが 0 件なので作る。
    case create
    /// アクティブになるセッションが終了済みなので再起動する。
    case restart(id: String)
}

/// セッション一覧とアクティブセッション（spec: daemon-connection「Session list synchronization」、
/// spec: tab-operations「Active session selection」）。
///
/// アクティブセッションはこのクライアントだけのもので、ほかのクライアントには影響しない。
@MainActor
public final class SessionStore {
    /// デーモンの順序どおりのセッション一覧。
    public private(set) var sessions: [SessionInfo] = []
    /// アクティブセッションの ID。無ければ nil。
    public private(set) var activeSessionID: String?
    /// 起動してから `sessions` フレームを 1 度でも受け取ったか。
    public private(set) var hasReceivedSessions = false

    /// 一覧かアクティブセッションが変わったときに呼ぶ。
    public var onChange: (() -> Void)?

    public init() {}

    /// アクティブセッション（一覧にあるもの）。
    public var activeSession: SessionInfo? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    /// `sessions` / `state` / `agent_state` フレームを反映する。ほかの種類は無視する。
    public func apply(_ frame: ServerFrame) {
        switch frame {
        case .sessions(let list):
            // 一覧は丸ごと置き換える。
            sessions = list
            hasReceivedSessions = true
            selectActiveAfterListChange()
        case .state(let update):
            guard let index = sessions.firstIndex(where: { $0.id == update.sid }) else { return }
            sessions[index].cwd = update.cwd
            sessions[index].command = update.cmd
            sessions[index].state = update.state
            sessions[index].exit = update.exit
            sessions[index].integrated = update.integrated
            sessions[index].runMs = update.runMs
        case .agentState(let update):
            guard let index = sessions.firstIndex(where: { $0.id == update.sid }) else { return }
            sessions[index].agent = update.agent
            sessions[index].agentState = update.agentState
            sessions[index].agentStateSince = update.agentStateSince
            sessions[index].agentStateSignal = update.agentStateSignal
            sessions[index].agentStateDetail = update.agentStateDetail
        default:
            return
        }
        onChange?()
    }

    /// 指定したセッションをアクティブにする（起動時に作った・再起動したセッションなど）。
    /// まだ一覧に無くてもよい（次の `sessions` フレームで一覧に入る）。
    public func activate(_ id: String) {
        activeSessionID = id
        onChange?()
    }

    /// 起動時のセッション確保で何をするか。最初の `sessions` を受け取る前は nil。
    public func bootstrapAction() -> SessionBootstrapAction? {
        guard hasReceivedSessions else { return nil }
        guard let first = sessions.first else { return .create }
        let active = activeSession ?? first
        return active.isExited ? .restart(id: active.id) : .useExisting
    }

    /// 一覧に残っていればそのまま、無ければ先頭（空なら無し）にする。
    private func selectActiveAfterListChange() {
        if let activeSessionID, sessions.contains(where: { $0.id == activeSessionID }) {
            return
        }
        activeSessionID = sessions.first?.id
    }
}
