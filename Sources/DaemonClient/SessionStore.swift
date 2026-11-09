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

/// 通知の対象になるイベント（phase3 design D3）。Phase 3 では未読の判定に、Phase 4 では通知の判定に使う。
public enum SessionEvent: Equatable, Sendable {
    /// `state` フレームで `running` から `idle` に変わった（コマンドが終わった）。値は反映した後のセッション。
    case commandFinished(SessionInfo)
    /// `notify` フレーム（title か body が空でないもの）。エージェントが入力を待っている、など。
    case agentWaiting(sid: String, title: String, body: String)

    /// イベントが起きたセッション。
    public var sid: String {
        switch self {
        case .commandFinished(let session): session.id
        case .agentWaiting(let sid, _, _): sid
        }
    }
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
    /// 通知の対象になるイベントが起きたときに呼ぶ（`onChange` の後）。
    public var onEvent: ((SessionEvent) -> Void)?

    public init() {}

    /// アクティブセッション（一覧にあるもの）。
    public var activeSession: SessionInfo? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    /// `sessions` / `state` / `agent_state` / `notify` フレームを反映する。ほかの種類は無視する。
    public func apply(_ frame: ServerFrame) {
        var event: SessionEvent?
        switch frame {
        case .sessions(let list):
            // 一覧は丸ごと置き換える。
            sessions = list
            hasReceivedSessions = true
            selectActiveAfterListChange()
        case .state(let update):
            guard let index = sessions.firstIndex(where: { $0.id == update.sid }) else { return }
            let previousState = sessions[index].state
            sessions[index].cwd = update.cwd
            sessions[index].command = update.cmd
            sessions[index].state = update.state
            sessions[index].exit = update.exit
            sessions[index].integrated = update.integrated
            sessions[index].runMs = update.runMs
            // 完了イベント: running → idle（webtabinal `App.tsx` と同じ条件）。
            if previousState == "running" && update.state == "idle" {
                event = .commandFinished(sessions[index])
            }
        case .agentState(let update):
            guard let index = sessions.firstIndex(where: { $0.id == update.sid }) else { return }
            sessions[index].agent = update.agent
            sessions[index].agentState = update.agentState
            sessions[index].agentStateSince = update.agentStateSince
            sessions[index].agentStateSignal = update.agentStateSignal
            sessions[index].agentStateDetail = update.agentStateDetail
        case .notify(let sid, let title, let body):
            // 待ちイベント: title か body が空でないもの（webtabinal `agentWaitContent` と同じ条件）。一覧は変わらない。
            guard sessions.contains(where: { $0.id == sid }), !Self.isBlank(title) || !Self.isBlank(body) else { return }
            onEvent?(.agentWaiting(sid: sid, title: title, body: body))
            return
        default:
            return
        }
        onChange?()
        if let event {
            onEvent?(event)
        }
    }

    /// セッションの `notifications_muted` をこのクライアントの中だけで変える（楽観的な更新と、失敗したときの取り消し）。
    /// デーモンの `sessions` が届けば、その値で置き換わる。
    public func setNotificationsMuted(_ id: String, _ muted: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].notificationsMuted != muted else { return }
        sessions[index].notificationsMuted = muted
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

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 一覧に残っていればそのまま、無ければ先頭（空なら無し）にする。
    private func selectActiveAfterListChange() {
        if let activeSessionID, sessions.contains(where: { $0.id == activeSessionID }) {
            return
        }
        activeSessionID = sessions.first?.id
    }
}
