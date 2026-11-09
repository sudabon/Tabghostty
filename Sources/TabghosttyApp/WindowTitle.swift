import Foundation

/// ウィンドウのタイトル（spec: app-shell「Main window」）。
public enum WindowTitle {
    public static let appName = "Tabghostty"

    /// `<directory> — Tabghostty`。アクティブセッションが無ければ `Tabghostty`。
    public static func make(cwd: String?, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        guard let cwd else { return appName }
        return "\(directoryName(cwd: cwd, home: home)) — \(appName)"
    }

    /// 作業ディレクトリの最後の要素。ホームと空の値は `~`、ルートは `/`。
    public static func directoryName(cwd: String, home: String) -> String {
        let path = trimTrailingSlashes(cwd)
        if path.isEmpty { return "~" }
        if path == "/" { return "/" }
        if path == trimTrailingSlashes(home) { return "~" }
        return path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? "/"
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
