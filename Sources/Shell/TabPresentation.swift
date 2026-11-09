import DaemonClient
import Foundation

/// 作業ディレクトリの最後の要素（webtabinal `web/src/util.ts` の `cwdBasename`）。
///
/// 空の値とホームディレクトリ（`/Users/<name>`、`/home/<name>`）は `~`、ルートは `/`。
public func cwdBasename(_ cwd: String) -> String {
    if cwd.isEmpty { return "~" }
    var normalized = cwd
    while normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    if normalized.isEmpty { normalized = "/" }
    if isHomeDirectory(normalized) { return "~" }
    let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
    let last = parts.last.map(String.init) ?? ""
    return last.isEmpty ? "/" : last
}

/// `/Users/<name>` か `/home/<name>`（Web 版の正規表現 `^/Users/[^/]+$` / `^/home/[^/]+$`）。
private func isHomeDirectory(_ path: String) -> Bool {
    for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
        let rest = path.dropFirst(prefix.count)
        if !rest.isEmpty && !rest.contains("/") { return true }
    }
    return false
}

/// 経過時間の `m:ss`（webtabinal `formatElapsed`）。nil・0・負の値は `0:00`。
public func formatElapsed(_ milliseconds: Int64?) -> String {
    guard let milliseconds, milliseconds > 0 else { return "0:00" }
    let total = milliseconds / 1000
    let minutes = total / 60
    let seconds = total % 60
    return "\(minutes):" + (seconds < 10 ? "0\(seconds)" : "\(seconds)")
}

/// エージェントの表示名（webtabinal `AgentStatePill.tsx` の `agentDisplayName`）。
public func agentDisplayName(_ id: String) -> String {
    switch id {
    case "": return "Agent"
    case "claude": return "Claude Code"
    case "codex": return "Codex"
    case "generic": return "Generic TUI"
    default: return id
    }
}

/// pill のアクセシビリティのラベル（`agentStateLabel`）。表示しない状態なら空。
public func agentStateLabel(agent: String, state: String) -> String {
    guard AgentPillModel.Kind(rawValue: state) != nil else { return "" }
    return "\(agentDisplayName(agent)) \(state)"
}

/// エージェントの状態 pill の表示内容（spec: tab-sidebar「Agent state pill」）。
public struct AgentPillModel: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case idle
        case working
        case blocked
    }

    public var kind: Kind
    /// pill に出す文字（小文字の状態名）。
    public var text: String
    /// 「Claude Code blocked」のようなラベル。
    public var accessibilityLabel: String
    /// working のときに回る印を出す（「視差効果を減らす」が有効なら止める）。
    public var showsSpinner: Bool { kind == .working }

    /// `agent_state` が idle / working / blocked のときだけ作る。`none`・空・それ以外の値は nil（pill を出さない）。
    public init?(agent: String, state: String) {
        guard let kind = Kind(rawValue: state) else { return nil }
        self.kind = kind
        text = state
        accessibilityLabel = agentStateLabel(agent: agent, state: state)
    }
}

/// サイドバーの行 1 つの表示内容（spec: tab-sidebar「Three-row tab presentation」）。`SessionInfo` だけから決まる。
public struct TabRowModel: Equatable, Sendable {
    /// 3 段目の色。
    public enum StateStyle: Equatable, Sendable {
        /// 実行中（accent）。
        case running
        /// 最後の終了コードが 0 以外（danger）。
        case error
        /// それ以外（muted）。
        case muted
    }

    public var id: String
    public var isActive: Bool
    public var isUnread: Bool
    /// 1 段目: 作業ディレクトリの最後の要素。
    public var title: String
    /// シェル統合が無効（`◌` を出す）。
    public var showsNoIntegration: Bool
    /// 2 段目: コマンド（空なら `zsh`）。
    public var command: String
    /// 2 段目のツールチップ（コマンド全体。空なら出さない）。
    public var commandToolTip: String?
    /// 実行中でなければ 2 段目を薄くする。
    public var isCommandDimmed: Bool
    /// 3 段目: `● running m:ss` / `■ exit N` / `○ starting` / `○ idle`。
    public var stateText: String
    public var stateStyle: StateStyle
    /// 終了済み（ほかの行と見分けられるようにする）。
    public var isExited: Bool
    public var pill: AgentPillModel?
    /// 前後の空白を削ったメモ（空ならツールチップを出さない）。
    public var memo: String

    public init(session: SessionInfo, isActive: Bool, isUnread: Bool) {
        id = session.id
        self.isActive = isActive
        self.isUnread = isUnread
        title = cwdBasename(session.cwd)
        showsNoIntegration = !session.integrated
        command = session.command.isEmpty ? "zsh" : session.command
        commandToolTip = session.command.isEmpty ? nil : session.command
        isCommandDimmed = session.state != "running"
        switch session.state {
        case "running":
            stateText = "● running \(formatElapsed(session.runMs))"
        case "exited":
            stateText = "■ exit \(session.exit.map(String.init) ?? "?")"
        case "starting":
            stateText = "○ starting"
        default:
            stateText = "○ idle"
        }
        // Web 版と同じく、0 以外の終了コードは実行中の色より優先する。
        if let exit = session.exit, exit != 0 {
            stateStyle = .error
        } else if session.state == "running" {
            stateStyle = .running
        } else {
            stateStyle = .muted
        }
        isExited = session.isExited
        pill = AgentPillModel(agent: session.agent, state: session.agentState)
        memo = session.memo.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
