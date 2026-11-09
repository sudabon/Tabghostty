import AppKit

/// About パネル（spec: app-shell「Version information in About」、phase7 design D3）。
///
/// アプリのバージョン（`CFBundleShortVersionString`）と、同梱したデーモンの出どころ
/// （`TabghosttyDaemonRevision`。`scripts/build-app.sh` が記録する）を出す。
/// 更新したあとに古いデーモンが残っていないかを切り分けるために使う。
@MainActor
enum AboutPanel {
    static let daemonRevisionKey = "TabghosttyDaemonRevision"

    /// About パネルを出す。
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: options(info: Bundle.main.infoDictionary ?? [:]))
    }

    /// `orderFrontStandardAboutPanel(options:)` に渡す値。
    /// バージョンが無い（`swift run`）ときは、`.applicationVersion` を入れずに AppKit の既定に任せる。
    static func options(info: [String: Any]) -> [NSApplication.AboutPanelOptionKey: Any] {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let version = nonEmptyString(info["CFBundleShortVersionString"]) {
            options[.applicationVersion] = version
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        options[.credits] = NSAttributedString(string: creditsText(info: info), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        return options
    }

    /// クレジット欄の文字列。デーモンを同梱していない（`.app` の外で起動した）ときは `none`。
    static func creditsText(info: [String: Any]) -> String {
        "Bundled daemon: \(nonEmptyString(info[daemonRevisionKey]) ?? "none")"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
