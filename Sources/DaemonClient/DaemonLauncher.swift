import DesktopSupport
import Foundation

/// デーモンの検出・起動に失敗した。
public enum DaemonLaunchError: Error, Equatable, LocalizedError {
    /// デーモン以外のプロセスがポートで待ち受けている。
    case portInUseByAnotherProcess(port: Int)
    /// 何かがポートで待ち受けているが、何度確かめても時間内に応答しなかった。
    case portNotResponding(port: Int)
    /// 同梱のデーモンが見つからない。
    case executableNotFound(path: String)
    /// 起動できなかった。
    case spawnFailed(reason: String)
    /// 起動したが、時間内に待ち受けを始めなかった。
    case timedOut(port: Int, seconds: Int, logPath: String)

    public var errorDescription: String? {
        switch self {
        case .portInUseByAnotherProcess(let port):
            return "Port \(port) is in use by a process that is not a compatible webtabinal daemon (another program, or an older daemon). Stop it, or change port in config.json."
        case .portNotResponding(let port):
            return "Something is listening on port \(port) but did not answer in time. If it is the webtabinal daemon, it may be busy; try again."
        case .executableNotFound(let path):
            return "The bundled webtabinal daemon was not found at \(path). Set TABGHOSTTY_DAEMON_PATH to the daemon binary when running outside the app bundle."
        case .spawnFailed(let reason):
            return "Failed to start the webtabinal daemon: \(reason)"
        case .timedOut(let port, let seconds, let logPath):
            return "The webtabinal daemon did not start listening on port \(port) within \(seconds) seconds. Check the log: \(logPath)"
        }
    }
}

/// デーモンが動いているかを確かめ、止まっていれば同梱のデーモンを起動して待つ（spec: daemon-connection「Detect or start the daemon」）。
public struct DaemonLauncher: Sendable {
    public typealias Probe = @Sendable (Int) -> WebTabinalProbeResult
    public typealias Spawn = @Sendable (_ executable: String, _ arguments: [String], _ logPath: String) throws -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public var port: Int
    public var executablePath: String
    public var logPath: String
    public var timeout: Duration = .seconds(15)
    /// 応答を読み切れなかったときに、確かめ直す回数。
    static let unverifiedRetries = 5
    public var interval: Duration = .milliseconds(150)
    var probe: Probe
    var spawn: Spawn
    var sleep: Sleep

    public init(
        port: Int,
        executablePath: String = DaemonLauncher.defaultExecutablePath(),
        logPath: String = DaemonPaths.daemonStdioLog.path,
        probe: @escaping Probe = { probeWebTabinal(port: $0) },
        spawn: @escaping Spawn = { executable, arguments, logPath in
            try spawnDetachedProcess(executablePath: executable, arguments: arguments, logPath: logPath)
        },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.executablePath = executablePath
        self.logPath = logPath
        self.probe = probe
        self.spawn = spawn
        self.sleep = sleep
    }

    /// デーモンの実行ファイルの場所。`TABGHOSTTY_DAEMON_PATH` があればそれを使い、
    /// 無ければ `.app` の `Contents/MacOS/webtabinal-daemon`（実行ファイルと同じディレクトリ）を探す。
    public static func defaultExecutablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String {
        if let override = environment["TABGHOSTTY_DAEMON_PATH"], !override.isEmpty {
            return override
        }
        if let url = bundle.url(forAuxiliaryExecutable: "webtabinal-daemon") {
            return url.path
        }
        let executableDirectory = bundle.executableURL?.deletingLastPathComponent()
            ?? bundle.bundleURL.appendingPathComponent("Contents/MacOS")
        return executableDirectory.appendingPathComponent("webtabinal-daemon").path
    }

    /// デーモンが待ち受けている状態にする。すでに動いていれば何もしない。
    /// - Returns: このプロセスがデーモンを起動したなら true
    @discardableResult
    public func ensureRunning() async throws -> Bool {
        // 待ち受けているが応答を読み切れない（忙しいデーモンかもしれない）なら、少し待って確かめ直す。
        var result = probe(port)
        var retries = 0
        while result == .unverified, retries < Self.unverifiedRetries {
            retries += 1
            try await sleep(interval)
            result = probe(port)
        }
        switch result {
        case .daemon:
            return false
        case .foreign:
            // 2 つ目のデーモンは起動しない。
            throw DaemonLaunchError.portInUseByAnotherProcess(port: port)
        case .unverified:
            // 何かが待ち受けているので、2 つ目のデーモンは起動しない。別のプロセスとも決めつけない。
            throw DaemonLaunchError.portNotResponding(port: port)
        case .notListening:
            break
        }

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw DaemonLaunchError.executableNotFound(path: executablePath)
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // setsid 付きで起動するので、アプリが終了してもデーモンは残る。
            try spawn(executablePath, ["serve"], logPath)
        } catch {
            throw DaemonLaunchError.spawnFailed(reason: error.localizedDescription)
        }

        // 0.15 秒間隔で最大 15 秒（= 100 回）確かめる。
        let attempts = max(1, Int((timeout / interval).rounded(.up)))
        var last = WebTabinalProbeResult.notListening
        for _ in 0..<attempts {
            try await sleep(interval)
            last = probe(port)
            if last == .daemon {
                return true
            }
        }
        if last == .foreign {
            throw DaemonLaunchError.portInUseByAnotherProcess(port: port)
        }
        throw DaemonLaunchError.timedOut(
            port: port,
            seconds: Int(timeout.components.seconds),
            logPath: logPath
        )
    }
}
