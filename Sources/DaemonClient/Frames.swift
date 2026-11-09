import Foundation
import TerminalCore

/// セッション 1 つ（デーモンの `session.Info`）。クライアントが知らないフィールドは無視する。
public struct SessionInfo: Equatable, Sendable, Decodable, Identifiable {
    public var id: String
    public var order: Int
    public var cwd: String
    public var command: String
    /// `starting` / `idle` / `running` / `exited`。
    public var state: String
    public var exit: Int?
    public var integrated: Bool
    public var memo: String
    /// このタブだけ通知のバナーを出さない（無ければ false）。
    public var notificationsMuted: Bool
    public var runMs: Int64?
    public var agent: String
    public var agentState: String
    public var agentStateSince: String
    public var agentStateSignal: String
    public var agentStateDetail: String?

    public var isExited: Bool { state == "exited" }

    public init(
        id: String,
        order: Int = 0,
        cwd: String = "",
        command: String = "",
        state: String = "idle",
        exit: Int? = nil,
        integrated: Bool = false,
        memo: String = "",
        notificationsMuted: Bool = false,
        runMs: Int64? = nil,
        agent: String = "",
        agentState: String = "",
        agentStateSince: String = "",
        agentStateSignal: String = "",
        agentStateDetail: String? = nil
    ) {
        self.id = id
        self.order = order
        self.cwd = cwd
        self.command = command
        self.state = state
        self.exit = exit
        self.integrated = integrated
        self.memo = memo
        self.notificationsMuted = notificationsMuted
        self.runMs = runMs
        self.agent = agent
        self.agentState = agentState
        self.agentStateSince = agentStateSince
        self.agentStateSignal = agentStateSignal
        self.agentStateDetail = agentStateDetail
    }

    enum CodingKeys: String, CodingKey {
        case id, order, cwd, command, state, exit, integrated, memo, agent
        case notificationsMuted = "notifications_muted"
        case runMs = "run_ms"
        case agentState = "agent_state"
        case agentStateSince = "agent_state_since"
        case agentStateSignal = "agent_state_signal"
        case agentStateDetail = "agent_state_detail"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        exit = try c.decodeIfPresent(Int.self, forKey: .exit)
        integrated = try c.decodeIfPresent(Bool.self, forKey: .integrated) ?? false
        memo = try c.decodeIfPresent(String.self, forKey: .memo) ?? ""
        notificationsMuted = try c.decodeIfPresent(Bool.self, forKey: .notificationsMuted) ?? false
        runMs = try c.decodeIfPresent(Int64.self, forKey: .runMs)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        agentState = try c.decodeIfPresent(String.self, forKey: .agentState) ?? ""
        agentStateSince = try c.decodeIfPresent(String.self, forKey: .agentStateSince) ?? ""
        agentStateSignal = try c.decodeIfPresent(String.self, forKey: .agentStateSignal) ?? ""
        agentStateDetail = try c.decodeIfPresent(String.self, forKey: .agentStateDetail)
    }
}

/// `state` フレーム（セッションの cwd / command / 状態）。
public struct SessionStateUpdate: Equatable, Sendable, Decodable {
    public var sid: String
    public var cwd: String
    public var cmd: String
    public var state: String
    public var exit: Int?
    public var integrated: Bool
    public var runMs: Int64?

    enum CodingKeys: String, CodingKey {
        case sid, cwd, cmd, state, exit, integrated
        case runMs = "run_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sid = try c.decode(String.self, forKey: .sid)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        cmd = try c.decodeIfPresent(String.self, forKey: .cmd) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        exit = try c.decodeIfPresent(Int.self, forKey: .exit)
        integrated = try c.decodeIfPresent(Bool.self, forKey: .integrated) ?? false
        runMs = try c.decodeIfPresent(Int64.self, forKey: .runMs)
    }
}

/// `agent_state` フレーム。
public struct AgentStateUpdate: Equatable, Sendable, Decodable {
    public var sid: String
    public var agent: String
    public var agentState: String
    public var agentStateSince: String
    public var agentStateSignal: String
    public var agentStateDetail: String?

    enum CodingKeys: String, CodingKey {
        case sid, agent
        case agentState = "agent_state"
        case agentStateSince = "agent_state_since"
        case agentStateSignal = "agent_state_signal"
        case agentStateDetail = "agent_state_detail"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sid = try c.decode(String.self, forKey: .sid)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        agentState = try c.decodeIfPresent(String.self, forKey: .agentState) ?? ""
        agentStateSince = try c.decodeIfPresent(String.self, forKey: .agentStateSince) ?? ""
        agentStateSignal = try c.decodeIfPresent(String.self, forKey: .agentStateSignal) ?? ""
        agentStateDetail = try c.decodeIfPresent(String.self, forKey: .agentStateDetail)
    }
}

/// デーモンから届くフレーム。
public enum ServerFrame: Equatable, Sendable {
    case sessions([SessionInfo])
    case state(SessionStateUpdate)
    case agentState(AgentStateUpdate)
    case replay(sid: String, data: [UInt8], done: Bool)
    case output(sid: String, data: [UInt8])
    case error(sid: String?, code: String?, message: String)
    case notify(sid: String, title: String, body: String)
    /// クライアントが知らない種類。無視する。
    case unknown(type: String)

    private struct Envelope: Decodable {
        let t: String
    }

    private struct SessionsBody: Decodable {
        let list: [SessionInfo]
    }

    private struct DataBody: Decodable {
        let sid: String
        let data: String?
        let done: Bool?
    }

    private struct ErrorBody: Decodable {
        let sid: String?
        let code: String?
        let message: String?
    }

    private struct NotifyBody: Decodable {
        let sid: String
        let title: String?
        let body: String?
    }

    /// 1 つのテキストメッセージを読む。JSON として読めないものは nil。
    public static func decode(_ data: Data) -> ServerFrame? {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        do {
            switch envelope.t {
            case "sessions":
                return .sessions(try decoder.decode(SessionsBody.self, from: data).list)
            case "state":
                return .state(try decoder.decode(SessionStateUpdate.self, from: data))
            case "agent_state":
                return .agentState(try decoder.decode(AgentStateUpdate.self, from: data))
            case "replay":
                let body = try decoder.decode(DataBody.self, from: data)
                return .replay(sid: body.sid, data: decodeBase64(body.data), done: body.done ?? false)
            case "output":
                let body = try decoder.decode(DataBody.self, from: data)
                return .output(sid: body.sid, data: decodeBase64(body.data))
            case "error":
                let body = try decoder.decode(ErrorBody.self, from: data)
                return .error(sid: body.sid, code: body.code, message: body.message ?? "")
            case "notify":
                let body = try decoder.decode(NotifyBody.self, from: data)
                return .notify(sid: body.sid, title: body.title ?? "", body: body.body ?? "")
            default:
                return .unknown(type: envelope.t)
            }
        } catch {
            // 形の合わないフレームも、接続は切らずに無視する。
            return .unknown(type: envelope.t)
        }
    }

    private static func decodeBase64(_ string: String?) -> [UInt8] {
        guard let string, !string.isEmpty, let data = Data(base64Encoded: string) else { return [] }
        return Array(data)
    }
}

extension TerminalOutgoingFrame {
    private struct Body: Encodable {
        let t: String
        let sid: String
        var data: String?
        var cols: Int?
        var rows: Int?
    }

    /// デーモンへ送る JSON（`{"t":"attach","sid":…}` など）。
    public func encodedJSON() -> Data {
        let body: Body
        switch self {
        case .attach(let sid):
            body = Body(t: "attach", sid: sid)
        case .input(let sid, let bytes):
            body = Body(t: "input", sid: sid, data: Data(bytes).base64EncodedString())
        case .resize(let sid, let cols, let rows):
            body = Body(t: "resize", sid: sid, cols: cols, rows: rows)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(body)) ?? Data()
    }
}
