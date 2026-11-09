import DesktopSupport
import Foundation

/// `color_scheme` の値。
public enum ColorSchemeSetting: String, Sendable, Equatable {
    case light, dark, system
}

/// 表示系の設定（config.json と `GET /api/config` の同じ名前のキー）。
public struct DisplaySettings: Equatable, Sendable {
    public static let defaultFontFamily = "Menlo, Monaco, 'Courier New', monospace"

    public var fontFamily: String = DisplaySettings.defaultFontFamily
    public var fontSize: Double = 14
    public var scrollbackLines: Int = 10_000
    public var colorScheme: ColorSchemeSetting = .system

    public init() {}

    public init(fontFamily: String, fontSize: Double, scrollbackLines: Int, colorScheme: ColorSchemeSetting) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.scrollbackLines = scrollbackLines
        self.colorScheme = colorScheme
    }

    /// JSON のオブジェクトから読む。無い・不正な値は既定値にする。未知のキーは無視する。
    init(json: [String: Any]) {
        if let family = json["font_family"] as? String,
           !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fontFamily = family
        }
        if let size = Self.number(json["font_size"]), size > 0 {
            fontSize = size
        }
        if let lines = Self.number(json["scrollback_lines"]), lines > 0, lines <= Double(Int32.max) {
            scrollbackLines = Int(lines)
        }
        if let scheme = json["color_scheme"] as? String, let value = ColorSchemeSetting(rawValue: scheme) {
            colorScheme = value
        }
    }

    /// 真偽値は数値として扱わない（JSON の `true` は NSNumber として読めてしまう）。
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

/// config.json の読み取りに失敗した。メッセージには config.json のパスを含めるが、内容（トークン）は含めない。
public enum DaemonConfigError: Error, Equatable, LocalizedError {
    case readFailed(path: String, reason: String)
    case parseFailed(path: String)
    case invalidPort(path: String)
    case missingAuthToken(path: String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let path, let reason):
            return "Failed to read the configuration at \(path): \(reason)"
        case .parseFailed(let path):
            return "Failed to parse the configuration at \(path). Check that config.json is valid JSON."
        case .invalidPort(let path):
            return "Invalid port in the configuration at \(path). port must be an integer between 1 and 65535."
        case .missingAuthToken(let path):
            return "The configuration at \(path) has no auth_token. Start the webtabinal daemon once to generate it."
        }
    }
}

/// webtabinal と共有する config.json（`~/Library/Application Support/WebTabinal/config.json`）の内容。
public struct DaemonConfig: Equatable, Sendable {
    public static let defaultPort = 8642

    /// config.json の場所。
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WebTabinal/config.json")
    }

    public var path: String
    /// 1〜65535。config.json に無いか 0 なら 8642。
    public var port: Int
    /// 認証トークン。config.json が無い（デーモンがまだ一度も起動していない）ときは nil。
    public var authToken: String?
    public var display: DisplaySettings

    public init(path: String, port: Int, authToken: String?, display: DisplaySettings) {
        self.path = path
        self.port = port
        self.authToken = authToken
        self.display = display
    }

    /// config.json を読む。ファイルが無ければ既定値（トークンは nil）を返す。
    public static func load(from url: URL = defaultURL) throws -> DaemonConfig {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return DaemonConfig(path: path, port: defaultPort, authToken: nil, display: DisplaySettings())
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DaemonConfigError.readFailed(path: path, reason: (error as NSError).localizedFailureReason ?? "permission denied or unreadable")
        }
        return try parse(data, path: path)
    }

    /// config.json の内容を解釈する。未知のキーは無視する。
    public static func parse(_ data: Data, path: String) throws -> DaemonConfig {
        let port: Int
        do {
            port = try configuredPort(from: data, path: path, defaultPort: defaultPort)
        } catch ConfigPortError.invalidPort {
            throw DaemonConfigError.invalidPort(path: path)
        } catch {
            throw DaemonConfigError.parseFailed(path: path)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DaemonConfigError.parseFailed(path: path)
        }
        let token = (json["auth_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DaemonConfig(path: path, port: port, authToken: token, display: DisplaySettings(json: json))
    }

    /// トークンを取り出す。無ければエラー。
    public func requireAuthToken() throws -> String {
        guard let authToken else { throw DaemonConfigError.missingAuthToken(path: path) }
        return authToken
    }
}

/// ログなどの場所。
public enum DaemonPaths {
    /// `~/Library/Logs/WebTabinal`
    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WebTabinal")
    }

    /// デーモンの標準出力・標準エラーを追記するファイル。
    public static var daemonStdioLog: URL { logDirectory.appendingPathComponent("daemon.stdio.log") }

    /// デーモン自身のログ。
    public static var daemonLog: URL { logDirectory.appendingPathComponent("daemon.log") }
}
