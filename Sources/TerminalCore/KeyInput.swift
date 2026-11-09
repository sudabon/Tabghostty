import GhosttyVt

/// 1 回のキー入力。`NSEvent` から作り、`VTTerminal.encodeKey(_:)` でバイト列にする。
///
/// AppKit に依存しないよう、`NSEvent` の値（keyCode・文字列・修飾キー）だけを受け取る。
public struct KeyInput: Equatable, Sendable {
    public enum Action: Sendable {
        case press
        case `repeat`
        case release
    }

    /// 修飾キー（libghostty の `GHOSTTY_MODS_*` と同じ意味）。
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SHIFT))
        public static let control = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CTRL))
        /// macOS の Option。
        public static let option = Modifiers(rawValue: UInt16(GHOSTTY_MODS_ALT))
        /// macOS の Command。
        public static let command = Modifiers(rawValue: UInt16(GHOSTTY_MODS_SUPER))
        public static let capsLock = Modifiers(rawValue: UInt16(GHOSTTY_MODS_CAPS_LOCK))
    }

    /// `GhosttyKey` の値（物理キー）。
    let keyRawValue: UInt32
    public var action: Action
    public var modifiers: Modifiers
    /// 文字の生成に使われた修飾キー（Shift や、文字を合成した Option）。
    public var consumedModifiers: Modifiers
    /// キーが生成した文字列（Ctrl などで変換する前のもの）。C0 制御文字や関数キーの私用領域の文字は含めない。
    public var text: String
    /// 修飾キーを押さないときの文字（Unicode scalar の値）。不明なら 0。
    public var unshiftedCodepoint: UInt32

    /// 物理キーがどれにも当たらない（文字だけを送る）。
    public var isUnidentifiedKey: Bool { keyRawValue == GHOSTTY_KEY_UNIDENTIFIED.rawValue }

    init(
        key: GhosttyKey,
        action: Action,
        modifiers: Modifiers,
        consumedModifiers: Modifiers,
        text: String,
        unshiftedCodepoint: UInt32
    ) {
        keyRawValue = key.rawValue
        self.action = action
        self.modifiers = modifiers
        self.consumedModifiers = consumedModifiers
        self.text = text
        self.unshiftedCodepoint = unshiftedCodepoint
    }

    /// macOS のキーイベントから作る。
    ///
    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`（仮想キーコード）
    ///   - characters: `NSEvent.characters`
    ///   - charactersIgnoringModifiers: `NSEvent.charactersIgnoringModifiers`（Shift だけは反映される）
    ///   - unshiftedCharacters: `NSEvent.characters(byApplyingModifiers: [])`。取れなければ nil
    ///   - modifiers: 押されている修飾キー
    ///   - isRepeat: `NSEvent.isARepeat`
    /// - Returns: 送るものが無いキー（物理キーも文字も不明）なら nil
    public static func mac(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        unshiftedCharacters: String?,
        modifiers: Modifiers,
        isRepeat: Bool = false
    ) -> KeyInput? {
        let key = macKeyTable[keyCode] ?? GHOSTTY_KEY_UNIDENTIFIED

        // Ctrl を押していると `characters` は制御文字になっているので、変換前の文字を使う。
        let rawText = modifiers.contains(.control) ? charactersIgnoringModifiers : characters
        let text = sanitizedText(rawText ?? "")

        if key == GHOSTTY_KEY_UNIDENTIFIED && text.isEmpty {
            return nil
        }

        var consumed: Modifiers = []
        if !text.isEmpty {
            // 文字の生成に使われた Shift / Option は、キーエンコーダに「消費済み」と伝える。
            consumed = modifiers.intersection([.shift, .option])
            if modifiers.contains(.control) {
                consumed.remove(.option)
            }
        }

        let unshiftedSource = unshiftedCharacters ?? charactersIgnoringModifiers?.lowercased() ?? ""
        let unshifted = sanitizedText(unshiftedSource).unicodeScalars.first.map(\.value) ?? 0

        return KeyInput(
            key: key,
            action: isRepeat ? .repeat : .press,
            modifiers: modifiers,
            consumedModifiers: consumed,
            text: text,
            unshiftedCodepoint: unshifted
        )
    }

    /// C0 制御文字・DEL・macOS の関数キー用の私用領域（U+F700〜U+F8FF）を取り除く
    /// （`ghostty_key_event_set_utf8` の約束。これらはキーの種類からエンコーダが作る）。
    static func sanitizedText(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            let value = scalar.value
            if value < 0x20 || value == 0x7F { return false }
            if (0xF700...0xF8FF).contains(value) { return false }
            return true
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// libghostty のキーエンコーダとキーイベント 1 組。`VTTerminal` が持ち、同じ actor の中で使う。
final class KeyEncoder {
    private let encoder: GhosttyKeyEncoder
    private let event: GhosttyKeyEvent

    init() throws {
        var encoder: GhosttyKeyEncoder?
        try VTTerminal.check(ghostty_key_encoder_new(nil, &encoder), "ghostty_key_encoder_new")
        guard let encoder else {
            throw VTError(function: "ghostty_key_encoder_new", code: GHOSTTY_INVALID_VALUE.rawValue)
        }
        var event: GhosttyKeyEvent?
        let result = ghostty_key_event_new(nil, &event)
        guard result == GHOSTTY_SUCCESS, let event else {
            ghostty_key_encoder_free(encoder)
            throw VTError(function: "ghostty_key_event_new", code: result.rawValue)
        }
        self.encoder = encoder
        self.event = event
    }

    deinit {
        ghostty_key_event_free(event)
        ghostty_key_encoder_free(encoder)
    }

    func encode(_ input: KeyInput, terminal: GhosttyTerminal) throws -> [UInt8] {
        // application cursor / keypad、kitty keyboard などの現在のモードを反映する。
        try VTTerminal.check(ghostty_key_encoder_set_from_terminal(encoder, terminal), "ghostty_key_encoder_set_from_terminal")

        let action: GhosttyKeyAction
        switch input.action {
        case .press: action = GHOSTTY_KEY_ACTION_PRESS
        case .repeat: action = GHOSTTY_KEY_ACTION_REPEAT
        case .release: action = GHOSTTY_KEY_ACTION_RELEASE
        }
        ghostty_key_event_set_action(event, action)
        ghostty_key_event_set_key(event, GhosttyKey(rawValue: input.keyRawValue))
        ghostty_key_event_set_mods(event, input.modifiers.rawValue)
        ghostty_key_event_set_consumed_mods(event, input.consumedModifiers.rawValue)
        ghostty_key_event_set_composing(event, false)
        ghostty_key_event_set_unshifted_codepoint(event, input.unshiftedCodepoint)

        // イベントは文字列をコピーしないので、エンコードが終わるまでバッファを生かしておき、終わったら外す。
        let utf8 = Array(input.text.utf8)
        defer { ghostty_key_event_set_utf8(event, GhosttyString(ptr: nil, len: 0)) }
        return try utf8.withUnsafeBufferPointer { text in
            ghostty_key_event_set_utf8(event, GhosttyString(ptr: text.baseAddress, len: text.count))
            return try encodeCurrentEvent()
        }
    }

    private func encodeCurrentEvent() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 64)
        var written = 0
        var result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &written)
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [UInt8](repeating: 0, count: written)
            result = ghostty_key_encoder_encode(encoder, event, &buffer, buffer.count, &written)
        }
        try VTTerminal.check(result, "ghostty_key_encoder_encode")
        return Array(buffer.prefix(written))
    }
}

/// macOS の仮想キーコード（`kVK_*`）から libghostty の物理キーへの対応。
/// Ghostty 本体（`src/input/keycodes.zig`）の macOS 列に合わせている。
private let macKeyTable: [UInt16: GhosttyKey] = [
    0x00: GHOSTTY_KEY_A, 0x01: GHOSTTY_KEY_S, 0x02: GHOSTTY_KEY_D, 0x03: GHOSTTY_KEY_F,
    0x04: GHOSTTY_KEY_H, 0x05: GHOSTTY_KEY_G, 0x06: GHOSTTY_KEY_Z, 0x07: GHOSTTY_KEY_X,
    0x08: GHOSTTY_KEY_C, 0x09: GHOSTTY_KEY_V, 0x0A: GHOSTTY_KEY_INTL_BACKSLASH, 0x0B: GHOSTTY_KEY_B,
    0x0C: GHOSTTY_KEY_Q, 0x0D: GHOSTTY_KEY_W, 0x0E: GHOSTTY_KEY_E, 0x0F: GHOSTTY_KEY_R,
    0x10: GHOSTTY_KEY_Y, 0x11: GHOSTTY_KEY_T, 0x12: GHOSTTY_KEY_DIGIT_1, 0x13: GHOSTTY_KEY_DIGIT_2,
    0x14: GHOSTTY_KEY_DIGIT_3, 0x15: GHOSTTY_KEY_DIGIT_4, 0x16: GHOSTTY_KEY_DIGIT_6, 0x17: GHOSTTY_KEY_DIGIT_5,
    0x18: GHOSTTY_KEY_EQUAL, 0x19: GHOSTTY_KEY_DIGIT_9, 0x1A: GHOSTTY_KEY_DIGIT_7, 0x1B: GHOSTTY_KEY_MINUS,
    0x1C: GHOSTTY_KEY_DIGIT_8, 0x1D: GHOSTTY_KEY_DIGIT_0, 0x1E: GHOSTTY_KEY_BRACKET_RIGHT, 0x1F: GHOSTTY_KEY_O,
    0x20: GHOSTTY_KEY_U, 0x21: GHOSTTY_KEY_BRACKET_LEFT, 0x22: GHOSTTY_KEY_I, 0x23: GHOSTTY_KEY_P,
    0x24: GHOSTTY_KEY_ENTER, 0x25: GHOSTTY_KEY_L, 0x26: GHOSTTY_KEY_J, 0x27: GHOSTTY_KEY_QUOTE,
    0x28: GHOSTTY_KEY_K, 0x29: GHOSTTY_KEY_SEMICOLON, 0x2A: GHOSTTY_KEY_BACKSLASH, 0x2B: GHOSTTY_KEY_COMMA,
    0x2C: GHOSTTY_KEY_SLASH, 0x2D: GHOSTTY_KEY_N, 0x2E: GHOSTTY_KEY_M, 0x2F: GHOSTTY_KEY_PERIOD,
    0x30: GHOSTTY_KEY_TAB, 0x31: GHOSTTY_KEY_SPACE, 0x32: GHOSTTY_KEY_BACKQUOTE, 0x33: GHOSTTY_KEY_BACKSPACE,
    0x35: GHOSTTY_KEY_ESCAPE,
    0x41: GHOSTTY_KEY_NUMPAD_DECIMAL, 0x43: GHOSTTY_KEY_NUMPAD_MULTIPLY, 0x45: GHOSTTY_KEY_NUMPAD_ADD,
    0x47: GHOSTTY_KEY_NUM_LOCK, 0x4B: GHOSTTY_KEY_NUMPAD_DIVIDE, 0x4C: GHOSTTY_KEY_NUMPAD_ENTER,
    0x4E: GHOSTTY_KEY_NUMPAD_SUBTRACT, 0x51: GHOSTTY_KEY_NUMPAD_EQUAL,
    0x52: GHOSTTY_KEY_NUMPAD_0, 0x53: GHOSTTY_KEY_NUMPAD_1, 0x54: GHOSTTY_KEY_NUMPAD_2, 0x55: GHOSTTY_KEY_NUMPAD_3,
    0x56: GHOSTTY_KEY_NUMPAD_4, 0x57: GHOSTTY_KEY_NUMPAD_5, 0x58: GHOSTTY_KEY_NUMPAD_6, 0x59: GHOSTTY_KEY_NUMPAD_7,
    0x5B: GHOSTTY_KEY_NUMPAD_8, 0x5C: GHOSTTY_KEY_NUMPAD_9,
    0x5D: GHOSTTY_KEY_INTL_YEN, 0x5E: GHOSTTY_KEY_INTL_RO, 0x5F: GHOSTTY_KEY_NUMPAD_COMMA,
    0x7A: GHOSTTY_KEY_F1, 0x78: GHOSTTY_KEY_F2, 0x63: GHOSTTY_KEY_F3, 0x76: GHOSTTY_KEY_F4,
    0x60: GHOSTTY_KEY_F5, 0x61: GHOSTTY_KEY_F6, 0x62: GHOSTTY_KEY_F7, 0x64: GHOSTTY_KEY_F8,
    0x65: GHOSTTY_KEY_F9, 0x6D: GHOSTTY_KEY_F10, 0x67: GHOSTTY_KEY_F11, 0x6F: GHOSTTY_KEY_F12,
    0x69: GHOSTTY_KEY_F13, 0x6B: GHOSTTY_KEY_F14, 0x71: GHOSTTY_KEY_F15, 0x6A: GHOSTTY_KEY_F16,
    0x40: GHOSTTY_KEY_F17, 0x4F: GHOSTTY_KEY_F18, 0x50: GHOSTTY_KEY_F19, 0x5A: GHOSTTY_KEY_F20,
    0x6E: GHOSTTY_KEY_CONTEXT_MENU, 0x72: GHOSTTY_KEY_INSERT,
    0x73: GHOSTTY_KEY_HOME, 0x74: GHOSTTY_KEY_PAGE_UP, 0x75: GHOSTTY_KEY_DELETE, 0x77: GHOSTTY_KEY_END,
    0x79: GHOSTTY_KEY_PAGE_DOWN,
    0x7B: GHOSTTY_KEY_ARROW_LEFT, 0x7C: GHOSTTY_KEY_ARROW_RIGHT, 0x7D: GHOSTTY_KEY_ARROW_DOWN, 0x7E: GHOSTTY_KEY_ARROW_UP,
]
