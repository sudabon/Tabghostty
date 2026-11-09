import DaemonClient
import TerminalCore

/// 設定が受け付けられない理由（webtabinal `keymap.ts` の `BindingIssue`）。
public enum BindingIssue: String, Equatable, Sendable {
    case prefixNoModifier = "prefix_no_modifier"
    case duplicateActionKey = "duplicate_action_key"
    case escape
    case unparsable
    case reserved
}

/// コードの判定の結果、すること。
public enum ChordAction: Equatable, Sendable {
    /// 関係ないキー（端末に送る）。
    case none
    /// プレフィックス（保留にする。保留中なら 3 秒を数え直す）。
    case arm
    case next
    case prev
    case toggleSidebar
    /// 保留を取り消す（そのキーは端末に送らない）。
    case cancel
}

/// コードの状態遷移の結果。
public struct ChordResolution: Equatable, Sendable {
    public var pending: Bool
    public var action: ChordAction

    public init(pending: Bool, action: ChordAction) {
        self.pending = pending
        self.action = action
    }
}

/// 隣のタブの向き。
public enum TabDirection: Sendable {
    case next
    case prev
}

/// キーの表記・検証・コードの状態遷移（webtabinal `web/src/keymap.ts` の移植。spec: keyboard-shortcuts）。
///
/// 表記は、修飾キーを `ctrl`・`alt`・`shift`・`meta` の順に並べ、最後にキーを 1 つ置いて `+` でつないだ小文字の文字列。
public enum Keymap {
    /// 保留したコードを取り消すまでの時間（3 秒）。
    public static let chordTimeout: Double = 3

    private static let modifierOrder = ["ctrl", "alt", "shift", "meta"]
    private static let reservedPrefixes: Set<String> = [
        "meta+1", "meta+2", "meta+3", "meta+4", "meta+5",
        "meta+6", "meta+7", "meta+8", "meta+9",
        "meta+n", "meta+c", "meta+v",
    ]

    // MARK: - 正規化

    /// キーイベントを表記に直す。修飾キーだけのキーと、IME で変換中のキーは nil。
    ///
    /// キーは、そのキーが作る文字（`charactersIgnoringModifiers`。Shift は反映される）を小文字にしたもの。
    /// 文字を作らないキー（Enter、矢印など）は、ブラウザの `KeyboardEvent.key` を小文字にした名前にする。
    public static func normalize(_ stroke: KeyStroke) -> String? {
        if stroke.isComposing { return nil }
        if KeyInput.modifier(forKeyCode: stroke.keyCode) != nil { return nil }
        let base: String
        if let name = namedKeys[stroke.keyCode] {
            base = name
        } else {
            let produced = stroke.charactersIgnoringModifiers ?? stroke.characters ?? ""
            guard !produced.isEmpty,
                  !produced.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || (0xF700...0xF8FF).contains($0.value) })
            else { return nil }
            base = produced == " " ? "space" : produced.lowercased()
        }
        return compose(base: base, modifiers: stroke.modifiers)
    }

    private static func compose(base: String, modifiers: KeyInput.Modifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("meta") }
        parts.append(base)
        return parts.joined(separator: "+")
    }

    /// 文字を作らないキー（macOS の仮想キーコード → ブラウザの `KeyboardEvent.key` の小文字）。
    private static let namedKeys: [UInt16: String] = [
        0x24: "enter", 0x4C: "enter", 0x30: "tab", 0x31: "space", 0x33: "backspace", 0x35: "escape",
        0x75: "delete", 0x72: "insert", 0x73: "home", 0x77: "end", 0x74: "pageup", 0x79: "pagedown",
        0x7B: "arrowleft", 0x7C: "arrowright", 0x7D: "arrowdown", 0x7E: "arrowup",
        0x7A: "f1", 0x78: "f2", 0x63: "f3", 0x76: "f4", 0x60: "f5", 0x61: "f6",
        0x62: "f7", 0x64: "f8", 0x65: "f9", 0x6D: "f10", 0x67: "f11", 0x6F: "f12",
    ]

    // MARK: - 表示

    /// 表示用の表記（`ctrl+j` → `Ctrl+J`、`meta` は `Cmd`）。
    public static func format(_ spec: String) -> String {
        guard !spec.isEmpty else { return "" }
        return spec.split(separator: "+", omittingEmptySubsequences: false).map { part in
            switch part {
            case "ctrl": return "Ctrl"
            case "alt": return "Alt"
            case "shift": return "Shift"
            case "meta": return "Cmd"
            default:
                guard let first = part.first else { return "" }
                return part.count == 1 ? part.uppercased() : first.uppercased() + part.dropFirst()
            }
        }.joined(separator: "+")
    }

    // MARK: - 検証

    struct ParsedBinding: Equatable {
        var modifiers: [String]
        var key: String
    }

    /// 表記を読む。小文字でない、空の部分がある、修飾キーの順序が違う・重なる、キーが修飾キーなら nil。
    static func parse(_ spec: String) -> ParsedBinding? {
        guard !spec.isEmpty, spec == spec.lowercased() else { return nil }
        let parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: \.isEmpty), let key = parts.last else { return nil }
        let modifiers = Array(parts.dropLast())
        var last = -1
        for modifier in modifiers {
            guard let index = modifierOrder.firstIndex(of: modifier), index > last else { return nil }
            last = index
        }
        guard !modifierOrder.contains(key) else { return nil }
        return ParsedBinding(modifiers: modifiers, key: key)
    }

    /// 設定を検証する（エラーの種類と判定の順序は Web 版と同じ）。問題が無ければ nil。
    public static func validate(_ bindings: KeyBindings) -> BindingIssue? {
        guard let prefix = parse(bindings.prefix),
              let next = parse(bindings.nextTab),
              let prev = parse(bindings.prevTab),
              let toggle = parse(bindings.toggleSidebar)
        else { return .unparsable }
        if [prefix, next, prev, toggle].contains(where: { $0.key == "escape" }) { return .escape }
        if prefix.modifiers.isEmpty { return .prefixNoModifier }
        if bindings.nextTab == bindings.prevTab
            || bindings.nextTab == bindings.toggleSidebar
            || bindings.prevTab == bindings.toggleSidebar {
            return .duplicateActionKey
        }
        if reservedPrefixes.contains(bindings.prefix) { return .reserved }
        return nil
    }

    // MARK: - 状態遷移

    /// コードの状態遷移（`resolveChordKey`）。
    /// - Parameters:
    ///   - pending: プレフィックスを押して保留中か
    ///   - spec: 正規化したキー（修飾キーだけ・変換中なら nil）
    public static func resolve(pending: Bool, spec: String?, bindings: KeyBindings) -> ChordResolution {
        guard bindings.enabled else { return ChordResolution(pending: false, action: .none) }
        guard let spec else { return ChordResolution(pending: pending, action: .none) }
        if spec == bindings.prefix { return ChordResolution(pending: true, action: .arm) }
        guard pending else { return ChordResolution(pending: false, action: .none) }
        if spec == "escape" { return ChordResolution(pending: false, action: .cancel) }
        if spec == bindings.nextTab { return ChordResolution(pending: false, action: .next) }
        if spec == bindings.prevTab { return ChordResolution(pending: false, action: .prev) }
        if spec == bindings.toggleSidebar { return ChordResolution(pending: false, action: .toggleSidebar) }
        return ChordResolution(pending: false, action: .cancel)
    }

    /// 隣のタブの位置（端で折り返す）。タブが 1 つならその位置、無い・アクティブが不明なら -1。
    public static func neighbourTabIndex(count: Int, activeIndex: Int, direction: TabDirection) -> Int {
        guard count > 0, activeIndex >= 0, activeIndex < count else { return -1 }
        if count == 1 { return activeIndex }
        switch direction {
        case .next: return (activeIndex + 1) % count
        case .prev: return (activeIndex - 1 + count) % count
        }
    }
}
