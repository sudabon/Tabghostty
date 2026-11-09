import Foundation
import Testing
@testable import DaemonClient

/// spec: daemon-connection「Authenticated requests」。
@Suite struct RESTClientTests {
    private let token = "f00dbabe-not-a-real-token-1234567890"

    private static let sessionJSON = #"""
    {"id":"s-new","order":0,"cwd":"/Users/me","command":"","state":"starting","exit":null,"integrated":false,
     "shell_exited":false,"prompt_seen":false,"memo":"","notifications_muted":false,"agent":"","agent_state":"none",
     "agent_state_since":"","agent_state_signal":"","some_future_field":42}
    """#

    @Test func requestsCarryBearerAndLoopbackHostWithoutOrigin() async throws {
        let server = try MockHTTPServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/config"):
                return .json(200, #"{"port":8642,"font_family":"Menlo","font_size":15,"scrollback_lines":2000,"color_scheme":"dark","auth_token":""}"#)
            case ("POST", "/api/sessions"):
                return .json(201, Self.sessionJSON)
            case ("POST", "/api/sessions/s-old/restart"):
                return .json(200, Self.sessionJSON)
            default:
                return .text(404, "Not Found", "not found")
            }
        }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)

        let display = try await client.fetchDisplaySettings()
        #expect(display == DisplaySettings(fontFamily: "Menlo", fontSize: 15, scrollbackLines: 2000, colorScheme: .dark))

        let created = try await client.createSession()
        #expect(created.id == "s-new")
        #expect(created.state == "starting")

        let restarted = try await client.restartSession(id: "s-old")
        #expect(restarted.id == "s-new")

        let requests = server.requests
        #expect(requests.map(\.path) == ["/api/config", "/api/sessions", "/api/sessions/s-old/restart"])
        for request in requests {
            #expect(request.headers["authorization"] == "Bearer \(token)")
            #expect(request.headers["host"] == "127.0.0.1:\(server.port)")
            #expect(request.headers["origin"] == nil)
            #expect(request.headers["cookie"] == nil)
        }
        #expect(requests[1].method == "POST")
        #expect((try JSONSerialization.jsonObject(with: requests[1].body) as? [String: Any])?.isEmpty == true)
    }

    // Scenario: Token is never printed
    @Test func unauthorizedErrorDoesNotContainTheToken() async throws {
        let server = try MockHTTPServer { _ in .text(401, "Unauthorized", "unauthorized\n") }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)

        let error = await #expect(throws: RESTError.self) { _ = try await client.fetchDisplaySettings() }
        #expect(error?.status == 401)
        let message = error.map { $0.localizedDescription } ?? ""
        #expect(message.contains("401"))
        #expect(message.contains(token) == false)
        #expect(String(describing: error as Any).contains(token) == false)
    }

    @Test func errorBodiesAreRedacted() async throws {
        let token = self.token
        let server = try MockHTTPServer { _ in .text(400, "Bad Request", "bad token \(token)\n") }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)

        let error = await #expect(throws: RESTError.self) { _ = try await client.createSession(cwd: "/tmp") }
        #expect(error?.status == 400)
        let message = error.map { $0.localizedDescription } ?? ""
        #expect(message.contains(token) == false)
        #expect(message.contains("<redacted>"))
    }

    @Test func connectionFailureIsReportedWithoutToken() async throws {
        let port = try await unusedLoopbackPort()
        let client = RESTClient(port: port, token: token)
        let error = await #expect(throws: RESTError.self) { _ = try await client.fetchDisplaySettings() }
        #expect(error?.status == nil)
        let message = error.map { $0.localizedDescription } ?? ""
        #expect(message.contains(token) == false)
    }
    // MARK: - タブの操作と設定の変更（phase3 tasks 2.1）

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @Test func tabOperationsSendTheExpectedRequests() async throws {
        let server = try MockHTTPServer { request in
            switch (request.method, request.path) {
            case ("POST", "/api/sessions/s%20one/duplicate"):
                return .json(201, Self.sessionJSON)
            case ("DELETE", "/api/sessions/s1"):
                return .text(204, "No Content", "")
            case ("PATCH", "/api/sessions/s1"):
                return .json(200, Self.sessionJSON)
            case ("PUT", "/api/sessions/order"):
                return .json(200, #"{"sessions":[]}"#)
            case ("PATCH", "/api/config"):
                return .json(200, #"{"port":8642,"sidebar_width":300,"quit_when_no_tabs":false,"auth_token":""}"#)
            default:
                return .text(404, "Not Found", "not found")
            }
        }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)

        let duplicated = try await client.duplicateSession(id: "s one")
        #expect(duplicated.id == "s-new")
        try await client.deleteSession(id: "s1")
        let memo = try await client.updateSessionMemo(id: "s1", memo: "レビュー対応")
        #expect(memo.id == "s-new")
        try await client.setSessionNotificationsMuted(id: "s1", muted: true)
        try await client.reorderSessions(ids: ["c", "a", "b"])
        let settings = try await client.patchConfig(ConfigPatch(sidebarWidth: 300))
        #expect(settings.tabs.sidebarWidth == 300)
        #expect(settings.tabs.quitWhenNoTabs == false)

        let requests = server.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "POST /api/sessions/s%20one/duplicate",
            "DELETE /api/sessions/s1",
            "PATCH /api/sessions/s1",
            "PATCH /api/sessions/s1",
            "PUT /api/sessions/order",
            "PATCH /api/config",
        ])
        #expect(requests[0].body.isEmpty)
        #expect(requests[1].body.isEmpty)
        #expect(Self.json(requests[2].body) as? [String: String] == ["memo": "レビュー対応"])
        #expect(Self.json(requests[3].body) as? [String: Bool] == ["notifications_muted": true])
        #expect(Self.json(requests[4].body) as? [String: [String]] == ["ids": ["c", "a", "b"]])
        #expect(Self.json(requests[5].body) as? [String: Int] == ["sidebar_width": 300])
        for request in requests {
            #expect(request.headers["authorization"] == "Bearer \(token)")
            #expect(request.headers["origin"] == nil)
        }
        for request in requests where !request.body.isEmpty {
            #expect(request.headers["content-type"] == "application/json")
        }
    }

    // spec: image-attach「Upload and type paths」— 生のバイト列を送り、`{path,name,mime,bytes}` を受け取る。413 / 415 は失敗。
    @Test func imageUploadSendsRawBytesAndReadsTheSavedPath() async throws {
        let server = try MockHTTPServer { request in
            switch request.path {
            case "/api/sessions/s1/images":
                return .json(201, #"{"path":"/Users/me/Library/Application Support/WebTabinal/images/img-1.png","name":"img-1.png","mime":"image/png","bytes":4}"#)
            case "/api/sessions/big/images":
                return .text(413, "Request Entity Too Large", "image exceeds size limit\n")
            default:
                return .text(415, "Unsupported Media Type", "unsupported image type\n")
            }
        }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])

        let saved = try await client.uploadImage(sessionID: "s1", data: bytes, mimeType: "image/png")
        #expect(saved == SavedImage(
            path: "/Users/me/Library/Application Support/WebTabinal/images/img-1.png", name: "img-1.png", mime: "image/png", bytes: 4
        ))
        await #expect(throws: RESTError.self) {
            _ = try await client.uploadImage(sessionID: "big", data: bytes, mimeType: "image/png")
        }
        do {
            _ = try await client.uploadImage(sessionID: "s2", data: Data("text".utf8), mimeType: "image/jpeg")
            Issue.record("an unsupported type must fail")
        } catch let error as RESTError {
            #expect(error.status == 415)
            #expect(error.detail == "unsupported image type")
        }

        let requests = server.requests
        #expect(requests.map { "\($0.method) \($0.path)" } == [
            "POST /api/sessions/s1/images", "POST /api/sessions/big/images", "POST /api/sessions/s2/images",
        ])
        #expect(requests[0].body == bytes)
        #expect(requests[0].headers["content-type"] == "image/png")
        #expect(requests[2].headers["content-type"] == "image/jpeg")
        #expect(requests[0].headers["authorization"] == "Bearer \(token)")
    }

    // 失敗したリクエストは、ステータスと本文を伝える。本文にトークンがあっても伏せる。
    @Test func tabOperationFailuresAreReportedWithoutTheToken() async throws {
        let token = self.token
        let server = try MockHTTPServer { request in
            if request.path == "/api/sessions/order" {
                return .text(400, "Bad Request", "ids must list every session \(token)\n")
            }
            return .text(400, "Bad Request", "session not found\n")
        }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)

        let operations: [(String, @Sendable () async throws -> Void)] = [
            ("POST /api/sessions/s1/duplicate", { _ = try await client.duplicateSession(id: "s1") }),
            ("DELETE /api/sessions/s1", { try await client.deleteSession(id: "s1") }),
            ("PATCH /api/sessions/s1", { try await client.updateSessionMemo(id: "s1", memo: "x") }),
            ("PATCH /api/sessions/s1", { try await client.setSessionNotificationsMuted(id: "s1", muted: false) }),
            ("PUT /api/sessions/order", { try await client.reorderSessions(ids: ["s1"]) }),
            ("PATCH /api/config", { try await client.patchConfig(ConfigPatch(sidebarWidth: 200)) }),
        ]
        for (label, operation) in operations {
            let error = await #expect(throws: RESTError.self, "\(label)") { try await operation() }
            #expect(error?.status == 400)
            #expect(error.map { "\($0.method) \($0.path)" } == label)
            let message = error.map { $0.localizedDescription } ?? ""
            #expect(message.contains("400"))
            #expect(message.contains(token) == false)
        }
        let orderError = await #expect(throws: RESTError.self) { try await client.reorderSessions(ids: ["s1"]) }
        #expect(orderError?.detail == "ids must list every session <redacted>")
    }

    @Test func unauthorizedTabOperationExplainsTheTokenWithoutPrintingIt() async throws {
        let server = try MockHTTPServer { _ in .text(401, "Unauthorized", "unauthorized\n") }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)
        let error = await #expect(throws: RESTError.self) { try await client.deleteSession(id: "s1") }
        #expect(error?.status == 401)
        #expect(error?.localizedDescription.contains(token) == false)
    }
}
