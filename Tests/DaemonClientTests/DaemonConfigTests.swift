import Foundation
import Testing
@testable import DaemonClient

/// spec: daemon-connection「Read daemon settings from the shared config file」。
@Suite struct DaemonConfigTests {
    private let path = "/Users/me/Library/Application Support/WebTabinal/config.json"
    private let secret = "0123456789abcdef-SECRET-TOKEN"

    private func parse(_ json: String) throws -> DaemonConfig {
        try DaemonConfig.parse(Data(json.utf8), path: path)
    }

    // Scenario: Default port
    @Test func missingPortUsesDefault() throws {
        let config = try parse(#"{"auth_token":"abc"}"#)
        #expect(config.port == 8642)
        #expect(config.authToken == "abc")
    }

    @Test func zeroPortUsesDefault() throws {
        #expect(try parse(#"{"port":0}"#).port == 8642)
    }

    @Test func missingFileUsesDefaultsWithoutToken() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)/config.json")
        let config = try DaemonConfig.load(from: url)
        #expect(config.port == 8642)
        #expect(config.authToken == nil)
        #expect(throws: DaemonConfigError.missingAuthToken(path: url.path)) { try config.requireAuthToken() }
    }

    @Test func explicitPortIsUsed() throws {
        #expect(try parse(#"{"port":9000,"auth_token":"t"}"#).port == 9000)
    }

    // Scenario: Invalid port
    @Test(arguments: [#"{"port":true}"#, #"{"port":70000}"#, #"{"port":-1}"#, #"{"port":"8642"}"#, #"{"port":1.5}"#])
    func invalidPortIsAConfigurationError(json: String) throws {
        let withToken = json.replacingOccurrences(of: "{", with: "{\"auth_token\":\"\(secret)\",")
        let error = #expect(throws: DaemonConfigError.self) { try parse(withToken) }
        #expect(error == .invalidPort(path: path))
        let message = error.map { $0.localizedDescription } ?? ""
        // config.json の場所を示し、トークンは含めない。
        #expect(message.contains(path))
        #expect(message.contains(secret) == false)
    }

    @Test func malformedJSONIsAParseErrorWithoutContent() throws {
        let error = #expect(throws: DaemonConfigError.self) { try parse("{\"auth_token\":\"\(secret)\",") }
        #expect(error == .parseFailed(path: path))
        let message = error.map { $0.localizedDescription } ?? ""
        #expect(message.contains(secret) == false)
    }

    @Test func displaySettingsAreReadAndUnknownKeysIgnored() throws {
        let config = try parse("""
        {
          "port": 8650,
          "auth_token": "t",
          "font_family": "'JetBrains Mono', Menlo, monospace",
          "font_size": 13,
          "scrollback_lines": 5000,
          "color_scheme": "light",
          "shell": "/bin/zsh",
          "future_option": {"nested": [1, 2, 3]}
        }
        """)
        #expect(config.port == 8650)
        #expect(config.display == DisplaySettings(
            fontFamily: "'JetBrains Mono', Menlo, monospace", fontSize: 13, scrollbackLines: 5000, colorScheme: .light
        ))
    }

    @Test func invalidDisplaySettingsFallBackToDefaults() throws {
        let config = try parse(#"{"font_family":"","font_size":true,"scrollback_lines":-3,"color_scheme":"sepia"}"#)
        #expect(config.display == DisplaySettings())
        #expect(config.display.fontFamily == "Menlo, Monaco, 'Courier New', monospace")
        #expect(config.display.fontSize == 14)
        #expect(config.display.scrollbackLines == 10_000)
        #expect(config.display.colorScheme == .system)
    }
}
