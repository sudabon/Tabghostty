import Darwin
import Foundation
import Testing
@testable import DesktopSupport

/// webtabinal `desktop/Tests/main.swift` のうち、ポートの解析・プローブ応答の判定・デタッチ起動のケースを移したもの。
@Suite struct DesktopSupportTests {
    // MARK: - ポートの解析

    @Test func configuredPortDefaultsMissingAndZero() throws {
        let missing = Data(#"{"shell":"/bin/zsh"}"#.utf8)
        let zero = Data(#"{"port":0}"#.utf8)
        #expect(try configuredPort(from: missing, path: "config.json", defaultPort: 8642) == 8642)
        #expect(try configuredPort(from: zero, path: "config.json", defaultPort: 8642) == 8642)
    }

    @Test func configuredPortPreservesValidValue() throws {
        let valid = Data(#"{"port":9000}"#.utf8)
        #expect(try configuredPort(from: valid, path: "config.json", defaultPort: 8642) == 9000)
    }

    @Test(arguments: [#"{"port":-1}"#, #"{"port":65536}"#, #"{"port":"8642"}"#, #"{"port":true}"#])
    func configuredPortRejectsInvalidValues(json: String) {
        #expect(throws: ConfigPortError.self) {
            _ = try configuredPort(from: Data(json.utf8), path: "config.json", defaultPort: 8642)
        }
    }

    // MARK: - プローブ応答の判定

    private static let validProbeResponse = [
        "HTTP/1.1 401 Unauthorized\r\n",
        "X-Frame-Options: DENY\r\n",
        "X-Content-Type-Options: nosniff\r\n",
        "Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; frame-ancestors 'none'; style-src 'self' 'unsafe-inline'\r\n",
        "Content-Length: 13\r\n",
        "\r\n",
        "unauthorized\n",
    ].joined()

    @Test func probeAcceptsWebTabinalSignature() {
        #expect(isWebTabinalProbeResponse(Data(Self.validProbeResponse.utf8)))
    }

    @Test func probeRejectsStaleCSP() {
        let staleCSP = [
            "HTTP/1.1 401 Unauthorized\r\n",
            "X-Frame-Options: DENY\r\n",
            "X-Content-Type-Options: nosniff\r\n",
            "Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; style-src 'self' 'unsafe-inline'\r\n",
            "Content-Length: 13\r\n",
            "\r\n",
            "unauthorized\n",
        ].joined()
        #expect(!isWebTabinalProbeResponse(Data(staleCSP.utf8)))
    }

    @Test func probeRejectsUnrelatedResponses() {
        let unrelated = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        let redirect = "HTTP/1.1 302 Found\r\nLocation: http://example.com/\r\nContent-Length: 0\r\n\r\n"
        #expect(!isWebTabinalProbeResponse(Data(unrelated.utf8)))
        #expect(!isWebTabinalProbeResponse(Data(redirect.utf8)))
    }

    // MARK: - デタッチ起動

    @Test func detachedSpawnCreatesSessionAndCapturesLogs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabghosttyDesktopSupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logPath = directory.appendingPathComponent("child.log").path

        let pid = try spawnDetachedProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf stdout; printf stderr >&2; sleep 5"],
            logPath: logPath
        )
        defer {
            // テストランナーから受け継いだシグナルの設定で SIGTERM が効かないことがあるので、
            // プロセスグループごと SIGKILL で止める（setsid したので pgid == pid）。
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }

        // 新しいセッションのリーダーになっている（アプリが終了しても巻き込まれない）。
        #expect(getsid(pid) == pid)

        let deadline = Date().addingTimeInterval(2)
        var output = ""
        repeat {
            if let data = FileManager.default.contents(atPath: logPath) {
                output = String(decoding: data, as: UTF8.self)
            }
            if output.contains("stdout") && output.contains("stderr") { break }
            usleep(10_000)
        } while Date() < deadline
        #expect(output.contains("stdout"))
        #expect(output.contains("stderr"))
    }
}
