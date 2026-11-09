import GhosttyVt

/// キーイベント 1 つの生の値（`NSEvent` から取り出したもの）。`classifyKey(_:settings:)` に渡す。
///
/// AppKit に依存しないので、判定の順序と条件を `NSEvent` を作らずに確かめられる（phase2 design D1）。
/// キーエンコーダに渡す値（`KeyInput`）は、判定のあとで作る。
public struct KeyStroke: Equatable, Sendable {
    public enum Phase: Sendable {
        /// keyDown（押し続けているときの繰り返しを含む）
        case down
        /// keyUp、または修飾キーを離した（`flagsChanged`）
        case up
    }

    public var phase: Phase
    /// `NSEvent.keyCode`（仮想キーコード）
    public var keyCode: UInt16
    /// `NSEvent.characters`
    public var characters: String?
    /// `NSEvent.charactersIgnoringModifiers`
    public var charactersIgnoringModifiers: String?
    public var modifiers: KeyInput.Modifiers
    /// IME で文字を変換している（未確定の文字列がある）。
    public var isComposing: Bool

    public init(
        phase: Phase = .down,
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String? = nil,
        modifiers: KeyInput.Modifiers = [],
        isComposing: Bool = false
    ) {
        self.phase = phase
        self.keyCode = keyCode
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.modifiers = modifiers
        self.isComposing = isComposing
    }

    /// Return（0x24）とテンキーの Enter（0x4C）。
    var isEnter: Bool { keyCode == 0x24 || keyCode == 0x4C }

    /// 修飾キーそのもの（Shift、Control など）。
    var isModifierKey: Bool { macModifierKeys[keyCode] != nil }

    /// 文字を作らないキー（Enter、Tab、Backspace、Escape、矢印、ファンクションキーなど）。
    ///
    /// `characters` が C0 制御文字・DEL・macOS の関数キー用の私用領域（U+F700〜U+F8FF）だけのキー。
    /// デッドキー（`characters` が空）は文字を作る途中なので、ここには含めない。
    var isNonTextKey: Bool {
        guard let characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value)
        }
    }
}

/// キーの判定に使う設定（spec: terminal-input）。
public struct KeySettings: Equatable, Sendable {
    /// Shift+Enter で `ESC CR` を送る（config の `shift_enter_newline`。既定は true）。
    public var shiftEnterNewline: Bool

    public init(shiftEnterNewline: Bool = true) {
        self.shiftEnterNewline = shiftEnterNewline
    }
}

/// キーイベントをどう扱うか。
public enum KeyAction: Equatable, Sendable {
    /// 何もしない。
    case ignore
    /// IME に渡す（`interpretKeyEvents`）。確定した文字列だけが `insertText` で届く。
    case inputMethod
    /// Command 付きのキー。メニューのキー等価物に任せ、セッションには送らない。
    case systemShortcut
    /// このテキストをそのまま送る（Shift+Enter の `ESC CR`、`¥` の `\`）。
    case send(String)
    /// キーエンコーダに直接渡す（Ctrl+文字、文字以外のキー、キーを離したとき）。
    case encode
    /// `interpretKeyEvents` に渡し、`insertText` で届いた文字を付けてキーエンコーダに渡す
    /// （Option で合成した文字やデッドキーもここを通る）。
    case interpret
}

/// Shift+Enter で送るシーケンス（`ESC CR`）。Claude Code などは改行の挿入として読む。
public let shiftEnterSequence = "\u{1b}\r"

/// キーイベントの扱いを決める（phase2 design D1。上から順に判定する）。
///
/// ```
/// 0. コードのプレフィックス（`TerminalView.keyChordHandler`。ここに来る前に判定する）
/// 1. 変換中                                   → IME に渡す
/// 2. Command を含む                           → メニューに任せる（送らない）
/// 3. Shift+Enter（shift_enter_newline が有効） → ESC CR
/// 4. ¥（Shift 以外の修飾キーなし）              → \
/// 5. Control を含む、または文字以外のキー        → キーエンコーダに直接
/// 6. それ以外                                 → interpretKeyEvents → insertText → キーエンコーダ
/// ```
///
/// キーを離したとき（`.up`）は、押したときに書き換えたキー（Shift+Enter、¥）と、
/// 変換中・Command 付きのキーを無視し、それ以外は離したことをキーエンコーダに渡す
/// （kitty keyboard protocol で離したことの報告を求められたときだけ、エンコーダが出力する）。
public func classifyKey(_ stroke: KeyStroke, settings: KeySettings) -> KeyAction {
    // 0. コードのプレフィックス（Ctrl+J）は、`TerminalView.keyDown` がここを呼ぶ前に判定する（phase3 design D4）。

    // 1. 変換中のキー（Enter / Escape / 矢印 / Backspace を含む）は IME のもの。
    if stroke.isComposing {
        return stroke.phase == .down ? .inputMethod : .ignore
    }

    // 2. Command 付きのキーはセッションに送らない。Command キー自体も送らない（組み合わせを送らないので）。
    if stroke.modifiers.contains(.command) || macModifierKeys[stroke.keyCode] == .command {
        return stroke.phase == .down ? .systemShortcut : .ignore
    }

    // 3 / 4. 書き換えるキー。離したときは何も送らない（押したことを報告していないので）。
    if let rewritten = rewrittenText(stroke, settings: settings) {
        return stroke.phase == .down ? .send(rewritten) : .ignore
    }

    if stroke.phase == .up {
        return .encode
    }

    // 5. Ctrl+文字を interpretKeyEvents に渡すと `insertNewline:` などのセレクタに変わってしまうので、直接渡す。
    if stroke.modifiers.contains(.control) || stroke.isNonTextKey || stroke.isModifierKey {
        return .encode
    }

    // 6.
    return .interpret
}

/// Shift+Enter と ¥ の書き換え（webtabinal `web/src/terminal-input.ts` と同じ条件）。
private func rewrittenText(_ stroke: KeyStroke, settings: KeySettings) -> String? {
    let others: KeyInput.Modifiers = [.control, .option, .command]
    // 3. Shift+Enter: Shift あり、Ctrl / Option / Command なし。
    if settings.shiftEnterNewline, stroke.isEnter, stroke.modifiers.contains(.shift),
       stroke.modifiers.isDisjoint(with: others) {
        return shiftEnterSequence
    }
    // 4. ¥: Ctrl / Option / Command なし（Shift は可）。打ったキーだけを書き換え、ペーストと IME の確定は書き換えない。
    if stroke.characters == "¥", stroke.modifiers.isDisjoint(with: others) {
        return "\\"
    }
    return nil
}

extension KeyInput {
    /// 修飾キー（`flagsChanged` の keyCode）が立てる修飾キーのフラグ。修飾キーでなければ nil。
    public static func modifier(forKeyCode keyCode: UInt16) -> Modifiers? {
        macModifierKeys[keyCode]
    }
}

/// 書記素クラスタ 1 つが端末で占めるセルの数（1 か 2）。IME の未確定の文字列を並べるのに使う。
public func terminalCellWidth(of character: Character) -> Int {
    let scalars = character.unicodeScalars.map(\.value)
    var width: UInt8 = 1
    scalars.withUnsafeBufferPointer { buffer in
        _ = ghostty_unicode_grapheme_width(buffer.baseAddress, buffer.count, &width)
    }
    return max(1, Int(width))
}
