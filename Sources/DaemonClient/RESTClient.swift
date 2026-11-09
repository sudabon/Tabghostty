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

/// デーモンが保存した画像（`POST /api/sessions/{id}/images` の応答）。
public struct SavedImage: Equatable, Sendable, Decodable {
    /// 保存先の絶対パス（エージェントのプロンプトに入力する）。
    public var path: String
    public var name: String
    public var mime: String
    public var bytes: Int

    public init(path: String, name: String = "", mime: String = "", bytes: Int = 0) {
        self.path = path
        self.name = name
        self.mime = mime
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mime = try c.decodeIfPresent(String.self, forKey: .mime) ?? ""
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case path, name, mime, bytes
    }
}

/// 画像のアップロード（テストで差し替える）。
public protocol ImageUploadAPI: Sendable {
    func uploadImage(sessionID: String, data: Data, mimeType: String) async throws -> SavedImage
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
    public func fetchSettings() async throws -> ClientSettings {
        let data = try await request("GET", "/api/config")
        return try decodeSettings(data, method: "GET")
    }

    /// `GET /api/config` のうち、端末の表示と入力の設定。
    public func fetchDisplaySettings() async throws -> DisplaySettings {
        try await fetchSettings().display
    }

    /// `PATCH /api/config`。デーモンは変更後の設定を返す。
    @discardableResult
    public func patchConfig(_ patch: ConfigPatch) async throws -> ClientSettings {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try await request("PATCH", "/api/config", body: try encoder.encode(patch))
        return try decodeSettings(data, method: "PATCH")
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

    /// `POST /api/sessions/{id}/duplicate`。同じ cwd で新しいセッションを作る。
    public func duplicateSession(id: String) async throws -> SessionInfo {
        let path = "/api/sessions/\(Self.escapePathComponent(id))/duplicate"
        let data = try await request("POST", path)
        return try decodeSession(data, method: "POST", path: path)
    }

    /// `DELETE /api/sessions/{id}`。デーモンは 204 を返す。
    public func deleteSession(id: String) async throws {
        _ = try await request("DELETE", "/api/sessions/\(Self.escapePathComponent(id))")
    }

    /// `PATCH /api/sessions/{id}` で `memo` を変える（空ならメモを消す）。
    @discardableResult
    public func updateSessionMemo(id: String, memo: String) async throws -> SessionInfo {
        try await patchSession(id: id, body: ["memo": memo])
    }

    /// `PATCH /api/sessions/{id}` で `notifications_muted` を変える。
    @discardableResult
    public func setSessionNotificationsMuted(id: String, muted: Bool) async throws -> SessionInfo {
        try await patchSession(id: id, body: ["notifications_muted": muted])
    }

    /// `PUT /api/sessions/order`。すべてのセッションの ID を新しい順序で送る。
    public func reorderSessions(ids: [String]) async throws {
        _ = try await request("PUT", "/api/sessions/order", body: try JSONSerialization.data(withJSONObject: ["ids": ids]))
    }

    /// `POST /api/sessions/{id}/images`。画像の生のバイト列を送り、デーモンが保存したファイルのパスを受け取る
    /// （spec: image-attach「Upload and type paths」）。10 MiB を超える（413）・対応していない形式（415）は失敗として投げる。
    public func uploadImage(sessionID: String, data: Data, mimeType: String) async throws -> SavedImage {
        let path = "/api/sessions/\(Self.escapePathComponent(sessionID))/images"
        let response = try await request("POST", path, body: data, contentType: mimeType)
        do {
            return try JSONDecoder().decode(SavedImage.self, from: response)
        } catch {
            throw RESTError(method: "POST", path: path, status: nil, detail: "the response is not a saved image")
        }
    }

    private func patchSession(id: String, body: [String: Any]) async throws -> SessionInfo {
        let path = "/api/sessions/\(Self.escapePathComponent(id))"
        let data = try await request("PATCH", path, body: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        return try decodeSession(data, method: "PATCH", path: path)
    }

    /// テスト用: リクエストを組み立てる。
    func makeRequest(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: makeRequest(method, path, body: body, contentType: contentType))
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

    private func decodeSettings(_ data: Data, method: String) throws -> ClientSettings {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RESTError(method: method, path: "/api/config", status: nil, detail: "the response is not a JSON object")
        }
        return ClientSettings(json: json)
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

extension RESTClient: ImageUploadAPI {}
