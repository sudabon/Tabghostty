import AppKit
import TerminalCore

/// 端末の入力の設定（config の `shift_enter_newline` と `copy_on_select`）。
///
/// 設定を変えたらすぐに反映できるよう、ビューは使うたびにここから読む（phase2 design D7）。値は `TabShellController` が
/// `ConfigStore` の変化に合わせて書き換える（phase4 design D4）。
@MainActor
public final class TerminalInputSettings {
    /// Shift+Enter で `ESC CR` を送る（既定は true）。
    public var shiftEnterNewline: Bool
    /// 選択を終えたら、そのテキストをコピーする（既定は false）。
    public var copyOnSelect: Bool

    public init(shiftEnterNewline: Bool = true, copyOnSelect: Bool = false) {
        self.shiftEnterNewline = shiftEnterNewline
        self.copyOnSelect = copyOnSelect
    }

    var keySettings: KeySettings {
        KeySettings(shiftEnterNewline: shiftEnterNewline)
    }
}

/// プログラムが OSC 52 で書き込んだテキストを `NSPasteboard` に書く（spec: terminal-clipboard「OSC 52 clipboard access」）。
///
/// `TerminalController`（actor）から呼ばれるので、メインスレッドに移ってから書く。
public final class PasteboardClipboard: TerminalClipboard, @unchecked Sendable {
    private let name: NSPasteboard.Name

    public init(name: NSPasteboard.Name = .general) {
        self.name = name
    }

    public func write(_ text: String) {
        let name = name
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard(name: name)
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
