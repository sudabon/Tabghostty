import GhosttyVt

/// マウスのイベント 1 つ（spec: terminal-mouse「Mouse reporting」）。`VTTerminal.encodeMouse` でバイト列にする。
public struct MouseInput: Equatable, Sendable {
    public enum Action: Sendable {
        case press
        case release
        case motion
    }

    public enum Button: Sendable, Hashable {
        case left
        case right
        case middle
        /// ホイールの上（X11 のボタン 4）
        case wheelUp
        /// ホイールの下（X11 のボタン 5）
        case wheelDown
        /// 戻る（macOS の `buttonNumber` 3、X11 のボタン 8）
        case back
        /// 進む（macOS の `buttonNumber` 4、X11 のボタン 9）
        case forward

        /// `NSEvent.buttonNumber` から作る。対応しないボタンなら nil。
        public init?(buttonNumber: Int) {
            switch buttonNumber {
            case 0: self = .left
            case 1: self = .right
            case 2: self = .middle
            case 3: self = .back
            case 4: self = .forward
            default: return nil
            }
        }

        var ghostty: GhosttyMouseButton {
            switch self {
            case .left: GHOSTTY_MOUSE_BUTTON_LEFT
            case .right: GHOSTTY_MOUSE_BUTTON_RIGHT
            case .middle: GHOSTTY_MOUSE_BUTTON_MIDDLE
            case .wheelUp: GHOSTTY_MOUSE_BUTTON_FOUR
            case .wheelDown: GHOSTTY_MOUSE_BUTTON_FIVE
            case .back: GHOSTTY_MOUSE_BUTTON_EIGHT
            case .forward: GHOSTTY_MOUSE_BUTTON_NINE
            }
        }
    }

    public var action: Action
    /// 押した / 離したボタン。ボタンを押さずに動かしたときは nil。
    public var button: Button?
    public var modifiers: KeyInput.Modifiers
    /// surface 座標（device pixel。ビューの左上が原点で、パディングを含む）。
    public var x: Double
    public var y: Double
    /// どれかのボタンを押したままか（button-event tracking でドラッグを報告するのに使う）。
    public var anyButtonPressed: Bool
    /// 端末の描画領域の大きさ（surface 座標をセルに直すのに使う）。
    public var surface: MouseSurface

    public init(
        action: Action,
        button: Button?,
        modifiers: KeyInput.Modifiers = [],
        x: Double,
        y: Double,
        anyButtonPressed: Bool,
        surface: MouseSurface
    ) {
        self.action = action
        self.button = button
        self.modifiers = modifiers
        self.x = x
        self.y = y
        self.anyButtonPressed = anyButtonPressed
        self.surface = surface
    }
}

/// 端末の描画領域の大きさ（すべて device pixel）。マウスエンコーダと選択のジェスチャーに渡す。
public struct MouseSurface: Equatable, Sendable {
    /// ビュー全体の幅・高さ。
    public var width: Int
    public var height: Int
    /// セルの幅・高さ。
    public var cellWidth: Int
    public var cellHeight: Int
    /// グリッドの外側の余白。
    public var paddingTop: Int
    public var paddingBottom: Int
    public var paddingLeft: Int
    public var paddingRight: Int
    /// グリッドの列数。
    public var columns: Int

    public init(
        width: Int,
        height: Int,
        cellWidth: Int,
        cellHeight: Int,
        paddingTop: Int,
        paddingBottom: Int,
        paddingLeft: Int,
        paddingRight: Int,
        columns: Int
    ) {
        self.width = width
        self.height = height
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        self.columns = columns
    }

    var encoderSize: GhosttyMouseEncoderSize {
        var size = GhosttyMouseEncoderSize()
        ghostty_sized_init(&size, MemoryLayout<GhosttyMouseEncoderSize>.size)
        size.screen_width = UInt32(max(1, width))
        size.screen_height = UInt32(max(1, height))
        size.cell_width = UInt32(max(1, cellWidth))
        size.cell_height = UInt32(max(1, cellHeight))
        size.padding_top = UInt32(max(0, paddingTop))
        size.padding_bottom = UInt32(max(0, paddingBottom))
        size.padding_left = UInt32(max(0, paddingLeft))
        size.padding_right = UInt32(max(0, paddingRight))
        return size
    }
}

/// 端末がどのマウス報告を有効にしているか（DECSET 9 / 1000 / 1002 / 1003）。
public enum MouseTracking: Sendable, Equatable {
    case none
    case x10
    case normal
    case button
    case any
}

/// libghostty のマウスエンコーダとマウスイベント 1 組。`VTTerminal` が持ち、同じ actor の中で使う。
final class MouseEncoder {
    private let encoder: GhosttyMouseEncoder
    private let event: GhosttyMouseEvent
    /// 端末のモードを次のエンコードの前に読み直す。
    ///
    /// `ghostty_mouse_encoder_set_from_terminal` は、同じセルへの移動を省く記録も消してしまうので、
    /// 端末に書き込んだあとだけ読み直す（移動が続いている間は、同じセルへの移動を送らない）。
    var needsSync = true
    /// 最後に設定した大きさと、ボタンを押したままか。設定し直しても同じセルの記録が消えるので、変わったときだけ設定する。
    private var lastSurface: MouseSurface?
    private var lastAnyButtonPressed: Bool?

    init() throws {
        var encoder: GhosttyMouseEncoder?
        try VTTerminal.check(ghostty_mouse_encoder_new(nil, &encoder), "ghostty_mouse_encoder_new")
        guard let encoder else {
            throw VTError(function: "ghostty_mouse_encoder_new", code: GHOSTTY_INVALID_VALUE.rawValue)
        }
        var event: GhosttyMouseEvent?
        let result = ghostty_mouse_event_new(nil, &event)
        guard result == GHOSTTY_SUCCESS, let event else {
            ghostty_mouse_encoder_free(encoder)
            throw VTError(function: "ghostty_mouse_event_new", code: result.rawValue)
        }
        self.encoder = encoder
        self.event = event
        var trackLastCell = true
        _ = ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)
    }

    deinit {
        ghostty_mouse_event_free(event)
        ghostty_mouse_encoder_free(encoder)
    }

    func encode(_ input: MouseInput, terminal: GhosttyTerminal) throws -> [UInt8] {
        if needsSync {
            try VTTerminal.check(ghostty_mouse_encoder_set_from_terminal(encoder, terminal), "ghostty_mouse_encoder_set_from_terminal")
            needsSync = false
        }
        if lastSurface != input.surface {
            var size = input.surface.encoderSize
            try VTTerminal.check(ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size), "ghostty_mouse_encoder_set(SIZE)")
            lastSurface = input.surface
        }
        if lastAnyButtonPressed != input.anyButtonPressed {
            var pressed = input.anyButtonPressed
            try VTTerminal.check(
                ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed),
                "ghostty_mouse_encoder_set(ANY_BUTTON_PRESSED)"
            )
            lastAnyButtonPressed = input.anyButtonPressed
        }

        let action: GhosttyMouseAction
        switch input.action {
        case .press: action = GHOSTTY_MOUSE_ACTION_PRESS
        case .release: action = GHOSTTY_MOUSE_ACTION_RELEASE
        case .motion: action = GHOSTTY_MOUSE_ACTION_MOTION
        }
        ghostty_mouse_event_set_action(event, action)
        if let button = input.button {
            ghostty_mouse_event_set_button(event, button.ghostty)
        } else {
            ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, input.modifiers.rawValue)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: Float(input.x), y: Float(input.y)))

        var buffer = [UInt8](repeating: 0, count: 128)
        var written = 0
        var result = ghostty_mouse_encoder_encode(encoder, event, &buffer, buffer.count, &written)
        if result == GHOSTTY_OUT_OF_SPACE {
            buffer = [UInt8](repeating: 0, count: written)
            result = ghostty_mouse_encoder_encode(encoder, event, &buffer, buffer.count, &written)
        }
        try VTTerminal.check(result, "ghostty_mouse_encoder_encode")
        return Array(buffer.prefix(written))
    }
}
