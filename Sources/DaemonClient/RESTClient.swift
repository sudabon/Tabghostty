import Foundation

/// REST リクエストが失敗した。メッセージに認証トークンは含めない。
public struct RESTError: Error, Equatable, LocalizedError {
    public var method: String
    public var path: String
    /// HTTP ステータス。接続できなかったときは nil。
    public var status: Int?
    public var detail: String

    public var errorDescription: String? {
        if let status {
            return "\(method) \(path) failed with HTTP \(status): \(detail)"
        }
        return "\(method) \(path) failed: \(detail)"
    }
}

/// デーモンの REST API（spec: daemon-connection「Authenticated requests」）。
///
/// すべてのリクエストに `Authorization: Bearer` を付け、`127.0.0.1:<port>` に送る。`Origin` は付けない。
public final class RESTClient: Sendable {
    public let port: Int
    private let token: String
    private let session: URLSession

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// `GET /api/config`（トークンを除いた設定）。
    public func fetchDisplaySettings() async throws -> DisplaySettings {
        let data = try await request("GET", "/api/config")
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RESTError(method: "GET", path: "/api/config", status: nil, detail: "the response is not a JSON object")
        }
        return DisplaySettings(json: json)
    }

    /// `POST /api/sessions`。`cwd` を省くとデーモンの既定（ホームディレクトリ）で作る。
    public func createSession(cwd: String? = nil) async throws -> SessionInfo {
        var body: [String: String] = [:]
        if let cwd { body["cwd"] = cwd }
        let data = try await request("POST", "/api/sessions", body: try JSONSerialization.data(withJSONObject: body))
        return try decodeSession(data, method: "POST", path: "/api/sessions")
    }

    /// `POST /api/sessions/{id}/restart`。終了済みのセッションを同じ位置で作り直す（新しい ID になる）。
    public func restartSession(id: String) async throws -> SessionInfo {
        let path = "/api/sessions/\(Self.escapePathComponent(id))/restart"
        let data = try await request("POST", path)
        return try decodeSession(data, method: "POST", path: path)
    }

    /// テスト用: リクエストを組み立てる。
    func makeRequest(_ method: String, _ path: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeRequest(method, path, body: body))
        } catch {
            throw RESTError(method: method, path: path, status: nil, detail: redact(error.localizedDescription))
        }
        guard let http = response as? HTTPURLResponse else {
            throw RESTError(method: method, path: path, status: nil, detail: "unexpected response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail: String
            if http.statusCode == 401 {
                detail = "the daemon rejected the auth token in config.json"
            } else {
                let text = String(decoding: data.prefix(512), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                detail = text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : redact(text)
            }
            throw RESTError(method: method, path: path, status: http.statusCode, detail: detail)
        }
        return data
    }

    private func decodeSession(_ data: Data, method: String, path: String) throws -> SessionInfo {
        do {
            return try JSONDecoder().decode(SessionInfo.self, from: data)
        } catch {
            throw RESTError(method: method, path: path, status: nil, detail: "the response is not a session")
        }
    }

    /// 念のため、どこから来た文字列でもトークンを伏せる。
    private func redact(_ text: String) -> String {
        guard !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "<redacted>")
    }

    private static func escapePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
