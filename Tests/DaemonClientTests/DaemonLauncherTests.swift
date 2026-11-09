import Darwin
import DesktopSupport
import Foundation
import os
import Testing
@testable import DaemonClient

/// spec: daemon-connection「Detect or start the daemon」。
@Suite struct DaemonLauncherTests {
    /// デーモンが返す 401 応答（webtabinal `internal/server/server.go` の contentSecurityPolicy と同じ）。
    static let daemonResponse = MockHTTPServer.Response.text(
        401, "Unauthorized", "unauthorized\n",
        headers: [
            ("X-Frame-Options", "DENY"),
            ("X-Content-Type-Options", "nosniff"),
            ("Content-Security-Policy", "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; frame-ancestors 'none'; style-src 'self' 'unsafe-inline'"),
            ("Content-Type", "text/plain; charset=utf-8"),
        ]
    )

    // MARK: - プローブの判定

    @Test func probeRecognizesTheDaemon() async throws {
        let server = try MockHTTPServer { _ in Self.daemonResponse }
        try await server.start()
        defer { server.stop() }
        let port = server.port
        let result = await Task.detached { probeWebTabinal(port: port) }.value
        #expect(result == .daemon)
        // トークン無しの GET /api/config を送っている。
        #expect(server.requests.first?.method == "GET")
        #expect(server.requests.first?.path == "/api/config")
        #expect(server.requests.first?.headers["authorization"] == nil)
    }

    // Scenario: Foreign process on the port
    @Test func probeRecognizesAForeignProcess() async throws {
        let server = try MockHTTPServer { _ in .text(404, "Not Found", "404 page not found\n") }
        try await server.start()
        defer { server.stop() }
        let port = server.port
        #expect(await Task.detached { probeWebTabinal(port: port) }.value == .foreign)
    }

    // 待ち受けているが応答しない（デーモンが忙しいなど）なら、別のプロセスとは決めつけない。
    @Test func probeReportsUnverifiedWhenNothingAnswers() async throws {
        // listen はするが accept も応答もしないソケット（接続はカーネルが受け付ける）。
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))
        #expect(await Task.detached { probeWebTabinal(port: port) }.value == .unverified)
    }

    @Test func probeRecognizesAClosedPort() async throws {
        let port = try await unusedLoopbackPort()
        #expect(await Task.detached { probeWebTabinal(port: port) }.value == .notListening)
    }

    // MARK: - 起動の流れ

    private final class Recorder: @unchecked Sendable {
        let spawns = OSAllocatedUnfairLock(initialState: [[String]]())
        let probes = OSAllocatedUnfairLock(initialState: 0)
    }

    private func launcher(
        results: [WebTabinalProbeResult],
        recorder: Recorder,
        executable: String = "/bin/sh"
    ) -> DaemonLauncher {
        DaemonLauncher(
            port: 8642,
            executablePath: executable,
            logPath: FileManager.default.temporaryDirectory.appendingPathComponent("tabghostty-test/daemon.stdio.log").path,
            probe: { _ in
                let index = recorder.probes.withLock { count -> Int in
                    defer { count += 1 }
                    return count
                }
                return results[min(index, results.count - 1)]
            },
            spawn: { executable, arguments, logPath in
                recorder.spawns.withLock { $0.append([executable] + arguments + [logPath]) }
            },
            sleep: { _ in }
        )
    }

    // Scenario: Daemon already running
    @Test func runningDaemonIsNotStartedAgain() async throws {
        let recorder = Recorder()
        let started = try await launcher(results: [.daemon], recorder: recorder).ensureRunning()
        #expect(started == false)
        #expect(recorder.spawns.withLock { $0 }.isEmpty)
    }

    // Scenario: Foreign process on the port
    @Test func foreignProcessIsAnErrorAndNoDaemonIsStarted() async throws {
        let recorder = Recorder()
        let error = await #expect(throws: DaemonLaunchError.self) {
            try await launcher(results: [.foreign], recorder: recorder).ensureRunning()
        }
        #expect(error == .portInUseByAnotherProcess(port: 8642))
        #expect(error?.localizedDescription.contains("8642") == true)
        #expect(recorder.spawns.withLock { $0 }.isEmpty)
    }

    // Scenario: Daemon not running
    @Test func stoppedDaemonIsStartedDetachedAndAwaited() async throws {
        let recorder = Recorder()
        let started = try await launcher(results: [.notListening, .notListening, .notListening, .daemon], recorder: recorder)
            .ensureRunning()
        #expect(started == true)
        let spawns = recorder.spawns.withLock { $0 }
        #expect(spawns.count == 1)
        #expect(spawns.first?.prefix(2) == ["/bin/sh", "serve"])
        #expect(spawns.first?.last?.hasSuffix("daemon.stdio.log") == true)
        #expect(recorder.probes.withLock { $0 } == 4)
    }

    // Scenario: Daemon fails to start
    @Test func timeoutPointsToTheLogFile() async throws {
        let recorder = Recorder()
        let error = await #expect(throws: DaemonLaunchError.self) {
            try await launcher(results: [.notListening], recorder: recorder).ensureRunning()
        }
        guard case .timedOut(let port, let seconds, let logPath)? = error else {
            Issue.record("unexpected error: \(String(describing: error))")
            return
        }
        #expect(port == 8642)
        #expect(seconds == 15)
        #expect(error?.localizedDescription.contains(logPath) == true)
        // 0.15 秒間隔で 15 秒 = 100 回確かめる（最初の 1 回を加えて 101 回）。
        #expect(recorder.probes.withLock { $0 } == 101)
    }

    // 応答を読み切れなかったら確かめ直す。デーモンだと分かれば、2 つ目は起動しない。
    @Test func unverifiedProbeIsRetriedBeforeDeciding() async throws {
        let recorder = Recorder()
        let started = try await launcher(results: [.unverified, .unverified, .daemon], recorder: recorder).ensureRunning()
        #expect(started == false)
        #expect(recorder.probes.withLock { $0 } == 3)
        #expect(recorder.spawns.withLock { $0 }.isEmpty)
    }

    // 何度確かめても応答しなければ、別のプロセスとは言わずに、応答しないことを伝える（デーモンは起動しない）。
    @Test func persistentlyUnverifiedPortIsReportedAsNotResponding() async throws {
        let recorder = Recorder()
        let error = await #expect(throws: DaemonLaunchError.self) {
            try await launcher(results: [.unverified], recorder: recorder).ensureRunning()
        }
        #expect(error == .portNotResponding(port: 8642))
        #expect(error?.localizedDescription.contains("not a compatible") == false)
        #expect(recorder.probes.withLock { $0 } == 1 + DaemonLauncher.unverifiedRetries)
        #expect(recorder.spawns.withLock { $0 }.isEmpty)
    }

    @Test func missingExecutableIsReported() async throws {
        let recorder = Recorder()
        let error = await #expect(throws: DaemonLaunchError.self) {
            try await launcher(results: [.notListening], recorder: recorder, executable: "/nonexistent/webtabinal-daemon")
                .ensureRunning()
        }
        #expect(error == .executableNotFound(path: "/nonexistent/webtabinal-daemon"))
        #expect(recorder.spawns.withLock { $0 }.isEmpty)
    }

    @Test func daemonPathCanBeOverridden() {
        let path = DaemonLauncher.defaultExecutablePath(environment: ["TABGHOSTTY_DAEMON_PATH": "/opt/webtabinal/bin/webtabinal"])
        #expect(path == "/opt/webtabinal/bin/webtabinal")

        let bundled = DaemonLauncher.defaultExecutablePath(environment: [:])
        #expect(bundled.hasSuffix("/webtabinal-daemon"))
    }
}
