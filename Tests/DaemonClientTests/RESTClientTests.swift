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
}
