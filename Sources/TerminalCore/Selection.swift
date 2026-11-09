import GhosttyVt

/// viewport の中のセルの位置（0 始まり）。
public struct GridPoint: Equatable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// 選択の操作 1 つ（spec: terminal-clipboard「Text selection」）。
///
/// ドラッグ、ダブルクリック、トリプルクリックの解釈は libghostty の選択のジェスチャーに任せる（phase2 design D3）。
public struct SelectionInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// ボタンを押した。`timeNanoseconds` と前回の押下から、何回目のクリックかをライブラリが決める。
        case press(timeNanoseconds: UInt64, repeatIntervalNanoseconds: UInt64, repeatDistance: Double)
        /// ドラッグした。
        case drag
        /// ボタンを離した。
        case release
        /// ビューの上下の端を越えてドラッグしている間、タイマーで送る（viewport を 1 行動かして選択を伸ばす）。
        case autoscrollTick
    }

    public var kind: Kind
    /// ポインタの下のセル（viewport の中に収めたもの）。
    public var cell: GridPoint
    /// surface 座標（device pixel）。
    public var x: Double
    public var y: Double
    public var surface: MouseSurface

    public init(kind: Kind, cell: GridPoint, x: Double, y: Double, surface: MouseSurface) {
        self.kind = kind
        self.cell = cell
        self.x = x
        self.y = y
        self.surface = surface
    }
}

/// libghostty の選択のジェスチャーと、操作ごとのイベント。`VTTerminal` が持ち、同じ actor の中で使う。
final class SelectionGesture {
    private let gesture: GhosttySelectionGesture
    private let press: GhosttySelectionGestureEvent
    private let release: GhosttySelectionGestureEvent
    private let drag: GhosttySelectionGestureEvent
    private let tick: GhosttySelectionGestureEvent
    /// ジェスチャーを使う端末。`VTTerminal` が持ち、端末を解放する前にこのオブジェクトを解放する。
    private let terminal: GhosttyTerminal

    init(terminal: GhosttyTerminal) throws {
        self.terminal = terminal
        var gesture: GhosttySelectionGesture?
        try VTTerminal.check(ghostty_selection_gesture_new(nil, &gesture), "ghostty_selection_gesture_new")
        guard let gesture else {
            throw VTError(function: "ghostty_selection_gesture_new", code: GHOSTTY_INVALID_VALUE.rawValue)
        }
        var events: [GhosttySelectionGestureEvent] = []
        for type in [
            GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE,
            GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK,
        ] {
            var event: GhosttySelectionGestureEvent?
            let result = ghostty_selection_gesture_event_new(nil, &event, type)
            guard result == GHOSTTY_SUCCESS, let event else {
                events.forEach(ghostty_selection_gesture_event_free)
                ghostty_selection_gesture_free(gesture, nil)
                throw VTError(function: "ghostty_selection_gesture_event_new", code: result.rawValue)
            }
            events.append(event)
        }
        self.gesture = gesture
        press = events[0]
        release = events[1]
        drag = events[2]
        tick = events[3]
    }

    deinit {
        ghostty_selection_gesture_event_free(press)
        ghostty_selection_gesture_event_free(release)
        ghostty_selection_gesture_event_free(drag)
        ghostty_selection_gesture_event_free(tick)
        ghostty_selection_gesture_free(gesture, terminal)
    }

    /// 進行中のジェスチャーをやめ、持っている参照を手放す（端末をリセットする前など）。
    func reset() {
        ghostty_selection_gesture_reset(gesture, terminal)
    }

    /// 操作を適用し、その結果の選択を返す。選択が無くなる操作なら nil。
    /// - Returns: `.unchanged` なら端末の選択を変えない（離したときなど）。
    func apply(_ input: SelectionInput) -> SelectionResult {
        let handle = terminal
        var ref = GhosttyGridRef()
        let point = GhosttyPoint(
            tag: GHOSTTY_POINT_TAG_VIEWPORT,
            value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(x: UInt16(clamping: input.cell.x), y: UInt32(clamping: input.cell.y)))
        )
        let hasRef = ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS
        var position = GhosttySurfacePosition(x: input.x, y: input.y)
        var geometry = GhosttySelectionGestureGeometry(
            columns: UInt32(max(1, input.surface.columns)),
            cell_width: UInt32(max(1, input.surface.cellWidth)),
            padding_left: UInt32(max(0, input.surface.paddingLeft)),
            screen_height: UInt32(max(1, input.surface.height))
        )

        let event: GhosttySelectionGestureEvent
        switch input.kind {
        case .press(let time, let interval, let distance):
            guard hasRef else { return .unchanged }
            event = press
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            var time = time
            var interval = interval
            var distance = distance
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
        case .drag:
            guard hasRef else { return .unchanged }
            event = drag
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        case .release:
            event = release
            if hasRef {
                ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)
            } else {
                ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil)
            }
        case .autoscrollTick:
            event = tick
            var viewport = point.value.coordinate
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &viewport)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
        }

        var selection = GhosttySelection()
        let result = ghostty_selection_gesture_event(gesture, handle, event, &selection)
        switch (input.kind, result) {
        case (.release, _):
            return .unchanged
        case (_, GHOSTTY_SUCCESS):
            return .select(selection)
        case (.autoscrollTick, _):
            // 動かす方向が無い、または押した位置が画面から消えた。選択はそのまま。
            return .unchanged
        case (_, GHOSTTY_NO_VALUE):
            // 1 回のクリック（ドラッグしていない）は選択を消す。
            return .clear
        default:
            return .unchanged
        }
    }

    /// 選択をドラッグしている途中で、viewport を自動で動かす方向。
    var autoscroll: GhosttySelectionGestureAutoscroll {
        var value = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
        _ = ghostty_selection_gesture_get(gesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &value)
        return value
    }
}

enum SelectionResult {
    case unchanged
    case clear
    case select(GhosttySelection)
}
