import GhosttyVt

/// セルの幅の種類（libghostty の `GhosttyCellWide`）。
public enum CellWidth: Sendable, Equatable {
    /// 1 セル。
    case narrow
    /// 2 セル幅の文字の先頭。グリフは 2 セル分の幅に描く。
    case wide
    /// 2 セル幅の文字の 2 セル目。描かない。
    case spacerTail
    /// 行末で 2 セル幅の文字が折り返されたときの、行末側の空きセル。描かない。
    case spacerHead
}

/// 下線の種類（SGR 4:x）。
public enum UnderlineStyle: Sendable, Equatable {
    case none, single, double, curly, dotted, dashed
}

/// セルの属性（SGR）。ビットの位置は `style.h` の `GHOSTTY_STYLE_FLAG_*` と同じ
/// （キャスト付きのマクロは Swift に取り込まれないので、値をここに書く）。
public struct CellAttributes: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = CellAttributes(rawValue: 1 << 0)
    public static let italic = CellAttributes(rawValue: 1 << 1)
    public static let faint = CellAttributes(rawValue: 1 << 2)
    public static let blink = CellAttributes(rawValue: 1 << 3)
    public static let inverse = CellAttributes(rawValue: 1 << 4)
    public static let invisible = CellAttributes(rawValue: 1 << 5)
    public static let strikethrough = CellAttributes(rawValue: 1 << 6)
    public static let overline = CellAttributes(rawValue: 1 << 7)

    /// `GHOSTTY_STYLE_UNDERLINE_MASK`（ビット 8〜10 に下線の種類が入る）。
    static let underlineMask: UInt16 = 0x7 << 8
    static let underlineShift: UInt16 = 8
}

/// 1 セル分の描画用データ（RenderState からコピーした値）。
public struct CellSnapshot: Sendable, Equatable {
    /// 書記素クラスタ。文字が無ければ空。
    public var text: String
    public var width: CellWidth
    /// 前景色。nil なら既定の前景色。パレットの色は解決済み。
    public var foreground: ColorRGB?
    /// 前景色がパレットの色なら、その番号（太字を明るい色で描くのに使う）。
    public var foregroundPaletteIndex: UInt8?
    /// 背景色。nil なら既定の背景色。
    public var background: ColorRGB?
    public var attributes: CellAttributes
    public var underline: UnderlineStyle
    /// 下線の色（SGR 58）。nil なら前景色。
    public var underlineColor: ColorRGB?

    public static let blank = CellSnapshot(
        text: "", width: .narrow, foreground: nil, foregroundPaletteIndex: nil, background: nil,
        attributes: [], underline: .none, underlineColor: nil
    )

    public init(
        text: String,
        width: CellWidth,
        foreground: ColorRGB?,
        foregroundPaletteIndex: UInt8?,
        background: ColorRGB?,
        attributes: CellAttributes,
        underline: UnderlineStyle,
        underlineColor: ColorRGB?
    ) {
        self.text = text
        self.width = width
        self.foreground = foreground
        self.foregroundPaletteIndex = foregroundPaletteIndex
        self.background = background
        self.attributes = attributes
        self.underline = underline
        self.underlineColor = underlineColor
    }
}

/// カーソルの形（DECSCUSR）。
public enum CursorShape: Sendable, Equatable {
    case block, underline, bar, hollowBlock
}

/// カーソルの描画用データ。
public struct CursorSnapshot: Sendable, Equatable {
    /// viewport 内の位置。カーソルが viewport の外にあるときは nil。
    public var x: Int
    public var y: Int
    public var visible: Bool
    public var blinking: Bool
    public var shape: CursorShape
    /// 2 セル幅の文字の 2 セル目にいる。
    public var onWideTail: Bool
}

/// 既定の色とパレット（OSC 4 / 10 / 11 / 12 で変わったものを含む）。
public struct FrameColors: Sendable, Equatable {
    public var foreground: ColorRGB
    public var background: ColorRGB
    /// 明示されたカーソル色。nil なら既定。
    public var cursor: ColorRGB?
    public var palette: [ColorRGB]
}

/// 1 フレーム分の描画データ。変化した行だけを持つ（`isFull` なら全行）。
///
/// libghostty の RenderState は actor の外へ持ち出せないので、値型にコピーしてから
/// メインスレッドの `TerminalView` に渡す（design D1）。
public struct FrameSnapshot: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    /// true なら全行を描き直す（`dirtyRows` に全行が入っている）。
    public var isFull: Bool
    /// 変化した行（viewport の y 座標と、その行のセル）。
    public var dirtyRows: [(y: Int, cells: [CellSnapshot])]
    /// 変化した行のうち、選択されている列の範囲（両端を含む）。選択の無い行は入っていない。
    public var selections: [Int: ClosedRange<Int>] = [:]
    public var colors: FrameColors
    public var cursor: CursorSnapshot?

    public static func == (lhs: FrameSnapshot, rhs: FrameSnapshot) -> Bool {
        lhs.cols == rhs.cols && lhs.rows == rhs.rows && lhs.isFull == rhs.isFull
            && lhs.colors == rhs.colors && lhs.cursor == rhs.cursor && lhs.selections == rhs.selections
            && lhs.dirtyRows.count == rhs.dirtyRows.count
            && zip(lhs.dirtyRows, rhs.dirtyRows).allSatisfy { $0.y == $1.y && $0.cells == $1.cells }
    }
}

/// libghostty の RenderState と、その行・セルのイテレータを持つ。`VTTerminal` と同じ actor の中で使う。
final class RenderStateReader {
    private let state: GhosttyRenderState
    private let rowIterator: GhosttyRenderStateRowIterator
    private let rowCells: GhosttyRenderStateRowCells
    private var textBuffer = [UInt8](repeating: 0, count: 64)

    init() throws {
        var state: GhosttyRenderState?
        try VTTerminal.check(ghostty_render_state_new(nil, &state), "ghostty_render_state_new")
        var iterator: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        let iteratorResult = ghostty_render_state_row_iterator_new(nil, &iterator)
        let cellsResult = ghostty_render_state_row_cells_new(nil, &cells)
        guard let state, let iterator, let cells else {
            if let state { ghostty_render_state_free(state) }
            if let iterator { ghostty_render_state_row_iterator_free(iterator) }
            if let cells { ghostty_render_state_row_cells_free(cells) }
            let failed = iteratorResult != GHOSTTY_SUCCESS ? iteratorResult : cellsResult
            throw VTError(function: "ghostty_render_state_row_*_new", code: failed.rawValue)
        }
        self.state = state
        self.rowIterator = iterator
        self.rowCells = cells
    }

    deinit {
        ghostty_render_state_row_cells_free(rowCells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(state)
    }

    /// Terminal から RenderState を更新し、変化した行をコピーする。読んだら dirty を消す。
    /// - Parameter forceFull: true なら dirty に関係なく全行を返す（ビューを作り直したときなど）。
    func snapshot(of terminal: GhosttyTerminal, forceFull: Bool) throws -> FrameSnapshot {
        try VTTerminal.check(ghostty_render_state_update(state, terminal), "ghostty_render_state_update")
        defer { ghostty_render_state_clean(state) }

        var cols: UInt16 = 0
        var rows: UInt16 = 0
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        if forceFull {
            var full = GHOSTTY_RENDER_STATE_DIRTY_FULL
            _ = ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_DIRTY, &full)
            dirty = full
        }

        var iterator: GhosttyRenderStateRowIterator? = rowIterator
        try VTTerminal.check(
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator),
            "ghostty_render_state_get(ROW_ITERATOR)"
        )

        var dirtyRows: [(y: Int, cells: [CellSnapshot])] = []
        var selections: [Int: ClosedRange<Int>] = [:]
        var y: UInt16 = 0
        while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
            dirtyRows.append((Int(y), try readRow(cols: Int(cols))))
            if let selected = readRowSelection() {
                selections[Int(y)] = selected
            }
        }

        return FrameSnapshot(
            cols: Int(cols),
            rows: Int(rows),
            isFull: dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL,
            dirtyRows: dirtyRows,
            selections: selections,
            colors: readColors(),
            cursor: readCursor()
        )
    }

    /// 今の行のうち、選択されている列の範囲。
    private func readRowSelection() -> ClosedRange<Int>? {
        var selection = GhosttyRenderStateRowSelection()
        ghostty_sized_init(&selection, MemoryLayout<GhosttyRenderStateRowSelection>.size)
        guard ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS,
              selection.start_x <= selection.end_x else {
            return nil
        }
        return Int(selection.start_x)...Int(selection.end_x)
    }

    private func readRow(cols: Int) throws -> [CellSnapshot] {
        var cellsHandle: GhosttyRenderStateRowCells? = rowCells
        try VTTerminal.check(
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle),
            "ghostty_render_state_row_get(CELLS)"
        )
        var cells: [CellSnapshot] = []
        cells.reserveCapacity(cols)
        while ghostty_render_state_row_cells_next(rowCells) {
            cells.append(readCell())
        }
        return cells
    }

    private func readCell() -> CellSnapshot {
        var cell = CellSnapshot.blank

        var raw: GhosttyCell = 0
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
            var wide = GHOSTTY_CELL_WIDE_NARROW
            if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                switch wide {
                case GHOSTTY_CELL_WIDE_WIDE: cell.width = .wide
                case GHOSTTY_CELL_WIDE_SPACER_TAIL: cell.width = .spacerTail
                case GHOSTTY_CELL_WIDE_SPACER_HEAD: cell.width = .spacerHead
                default: cell.width = .narrow
                }
            }
        }

        cell.text = readText()

        // 文字の無いセルでも、消去時の背景色（content tag）を持つことがあるので、背景色は常に読む。
        var background = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &background) == GHOSTTY_SUCCESS {
            cell.background = ColorRGB(background)
        }

        var hasStyling = false
        _ = ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
        guard hasStyling else { return cell }

        var style = GhosttyStyle()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS {
            cell.attributes = CellAttributes(rawValue: style.flags & ~CellAttributes.underlineMask)
            switch Int((style.flags & CellAttributes.underlineMask) >> CellAttributes.underlineShift) {
            case Int(GHOSTTY_SGR_UNDERLINE_SINGLE.rawValue): cell.underline = .single
            case Int(GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue): cell.underline = .double
            case Int(GHOSTTY_SGR_UNDERLINE_CURLY.rawValue): cell.underline = .curly
            case Int(GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue): cell.underline = .dotted
            case Int(GHOSTTY_SGR_UNDERLINE_DASHED.rawValue): cell.underline = .dashed
            default: cell.underline = .none
            }
            if style.fg_color.tag == UInt8(GHOSTTY_STYLE_COLOR_PALETTE.rawValue) {
                cell.foregroundPaletteIndex = style.fg_color.value.palette
            }
            if style.underline_color.tag == UInt8(GHOSTTY_STYLE_COLOR_RGB.rawValue) {
                cell.underlineColor = ColorRGB(style.underline_color.value.rgb)
            }
        }
        var foreground = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &foreground) == GHOSTTY_SUCCESS {
            cell.foreground = ColorRGB(foreground)
        }
        return cell
    }

    private func readText() -> String {
        var buffer = GhosttyBuffer()
        var result = textBuffer.withUnsafeMutableBufferPointer { storage -> GhosttyResult in
            buffer.ptr = storage.baseAddress
            buffer.cap = storage.count
            return ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer)
        }
        if result == GHOSTTY_OUT_OF_SPACE {
            textBuffer = [UInt8](repeating: 0, count: max(buffer.len, textBuffer.count * 2))
            result = textBuffer.withUnsafeMutableBufferPointer { storage -> GhosttyResult in
                buffer.ptr = storage.baseAddress
                buffer.cap = storage.count
                return ghostty_render_state_row_cells_get(rowCells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer)
            }
        }
        guard result == GHOSTTY_SUCCESS, buffer.len > 0 else { return "" }
        return String(decoding: textBuffer.prefix(buffer.len), as: UTF8.self)
    }

    private func readColors() -> FrameColors {
        var colors = GhosttyRenderStateColors()
        ghostty_sized_init(&colors, MemoryLayout<GhosttyRenderStateColors>.size)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let palette = withUnsafeBytes(of: colors.palette) { raw in
            Array(raw.bindMemory(to: GhosttyColorRgb.self)).map(ColorRGB.init)
        }
        return FrameColors(
            foreground: ColorRGB(colors.foreground),
            background: ColorRGB(colors.background),
            cursor: colors.cursor_has_value ? ColorRGB(colors.cursor) : nil,
            palette: palette
        )
    }

    private func readCursor() -> CursorSnapshot? {
        var cursor = GhosttyRenderStateCursor()
        ghostty_sized_init(&cursor, MemoryLayout<GhosttyRenderStateCursor>.size)
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor) == GHOSTTY_SUCCESS,
              cursor.viewport_has_value else {
            return nil
        }
        let shape: CursorShape
        switch cursor.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: shape = .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: shape = .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: shape = .hollowBlock
        default: shape = .block
        }
        return CursorSnapshot(
            x: Int(cursor.viewport_x),
            y: Int(cursor.viewport_y),
            visible: cursor.visible,
            blinking: cursor.blinking,
            shape: shape,
            onWideTail: cursor.wide_tail
        )
    }
}

extension VTTerminal {
    /// 描画用のスナップショットを作る（変化した行だけ）。
    public func makeSnapshot(forceFull: Bool = false) throws -> FrameSnapshot {
        if renderReader == nil {
            renderReader = try RenderStateReader()
        }
        return try renderReader!.snapshot(of: handle, forceFull: forceFull)
    }
}
