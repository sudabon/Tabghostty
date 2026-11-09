import DaemonClient
import Foundation

/// 設定画面の入力を確定するときの決まり（webtabinal `GeneralSettings.tsx` / `NotificationsSettings.tsx` /
/// `KeyboardSettings.tsx` の移植。spec: settings-window）。
public enum SettingsRules {
    /// テキストを確定したときにすること。
    public enum Commit: Equatable, Sendable {
        /// 保存せずに、保存済みの値に戻す。
        case revert
        /// この値を保存する。
        case save(String)
    }

    /// 起動シェルを確定する: 前後の空白を削り、空か変わっていなければ保存せずに戻す。
    public static func shellCommit(_ text: String, persisted: String) -> Commit {
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty, next != persisted else { return .revert }
        return .save(next)
    }

    /// マニフェストディレクトリを確定する: 前後の空白を削り、変わっていなければ保存しない（空は「既定のディレクトリ」として保存する）。
    public static func manifestDirCommit(_ text: String, persisted: String) -> Commit {
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != persisted else { return .revert }
        return .save(next)
    }

    /// 数値の欄を確定する: JavaScript の `parseInt(raw, 10)` と同じく先頭の整数を読み、数値でないか変わっていなければ nil（戻す）。
    /// 範囲の検証はデーモンに任せる（拒否されたら戻してエラーを出す）。
    public static func numberCommit(_ text: String, persisted: Int) -> Int? {
        guard let value = parseInt(text), value != persisted else { return nil }
        return value
    }

    /// `parseInt(raw, 10)`: 前の空白を飛ばし、符号と続く数字を読む。数字が無ければ nil。
    public static func parseInt(_ text: String) -> Int? {
        var scalars = Substring(text).drop { $0.isWhitespace }
        var sign = ""
        if let first = scalars.first, first == "+" || first == "-" {
            sign = first == "-" ? "-" : ""
            scalars = scalars.dropFirst()
        }
        let digits = scalars.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(sign + digits)
    }

    /// 通知するコマンドを追加する: 前後の空白を削り、空か、大文字小文字を区別せずに同じものがあれば nil（保存しない）。
    public static func addingCommand(_ draft: String, to commands: [String]) -> [String]? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !commands.contains(where: { $0.lowercased() == name.lowercased() }) else { return nil }
        return commands + [name]
    }

    /// 通知するコマンドから外す。
    public static func removingCommand(_ name: String, from commands: [String]) -> [String] {
        commands.filter { $0 != name }
    }

    /// キー割り当てを検証したときのメッセージ（Web 版の `ISSUE_MESSAGE`）。
    public static func message(for issue: BindingIssue) -> String {
        switch issue {
        case .prefixNoModifier: "プレフィックスキーには修飾キー（Ctrl / Alt / Shift / Cmd）が必要です"
        case .duplicateActionKey: "移動キーとサイドバー開閉キーに同じキーは使えません"
        case .escape: "Escape は割り当てできません"
        case .unparsable: "このキーは割り当てできません"
        case .reserved: "既存のショートカット（Cmd+1〜9 / Cmd+N / Cmd+C / Cmd+V）と衝突しています"
        }
    }

    /// 「キー割り当てをリセット」: 既定の割り当てに戻す（有効かどうかはそのまま）。
    public static func resetBindings(keepingEnabledFrom bindings: KeyBindings) -> KeyBindings {
        var reset = KeyBindings.default
        reset.enabled = bindings.enabled
        return reset
    }
}
