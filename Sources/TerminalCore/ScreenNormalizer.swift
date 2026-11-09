import GhosttyVt

/// 画面をテキストの行に正規化する（spec: engine-parity、phase6 design D5）。
///
/// デーモンの画面モデル（`daemon/internal/vtscreen` の `Snapshot.Lines`。ghostty 版は `ghostty.go`）と同じ規則で、表示中の行をテキストにする。
/// - 表示中の行（active area）だけを対象にし、スクロールバックは含めない
/// - wide 文字の 2 セル目（継続セル）は飛ばす
/// - 結合文字は前の文字に付ける。libghostty は結合文字を前のセルの書記素クラスタに入れるので、セルの書記素をそのまま並べる。
///   書記素が結合文字から始まるセルがあれば、文字列をつなげた時点で前の文字に付く
/// - 文字の無いセルは空白 1 つにし、行末の空白（U+0020 だけ）を削る
public enum ScreenNormalizer {
    /// 正規化に使うセルの情報。
    public struct Cell: Sendable, Equatable {
        /// 書記素クラスタ。文字が無ければ空。
        public var text: String
        public var width: CellWidth

        public init(text: String, width: CellWidth = .narrow) {
            self.text = text
            self.width = width
        }
    }

    /// 1 行分のセルをテキストにする。
    public static func line(_ cells: some Sequence<Cell>) -> String {
        var line = ""
        for cell in cells {
            switch cell.width {
            case .spacerTail:
                // wide 文字の 2 セル目。文字は先頭のセルにある。
                continue
            case .spacerHead:
                // 行末で wide 文字が次の行へ折り返されたときの空きセル。
                line.append(" ")
            case .narrow, .wide:
                line += cell.text.isEmpty ? " " : cell.text
            }
        }
        // Go の strings.TrimRight(s, " ") と同じく、U+0020 だけを削る。
        while line.unicodeScalars.last == " " {
            line.unicodeScalars.removeLast()
        }
        return line
    }

    /// 行ごとのセルを、行ごとのテキストにする。
    public static func lines(_ rows: [[Cell]]) -> [String] {
        rows.map { line($0) }
    }
}

extension VTTerminal {
    /// 表示中の画面（アクティブな画面の active area）を正規化した行。行数は `rows` と同じ。
    ///
    /// セルは grid ref で読むので、描画用の RenderState の dirty には影響しない。
    public func normalizedScreenLines() -> [String] {
        var codepoints = [UInt32](repeating: 0, count: 8)
        return (0..<rows).map { y in
            let cells = (0..<cols).map { x in
                activeCell(x: x, y: y, codepoints: &codepoints)
            }
            return ScreenNormalizer.line(cells)
        }
    }

    /// active area のセル (x, y)。読めなければ文字の無いセルとして扱う。
    private func activeCell(x: Int, y: Int, codepoints: inout [UInt32]) -> ScreenNormalizer.Cell {
        var ref = GhosttyGridRef()
        let point = GhosttyPoint(
            tag: GHOSTTY_POINT_TAG_ACTIVE,
            value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y)))
        )
        guard ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS else {
            return ScreenNormalizer.Cell(text: "")
        }

        var width = CellWidth.narrow
        var raw: GhosttyCell = 0
        if ghostty_grid_ref_cell(&ref, &raw) == GHOSTTY_SUCCESS {
            var wide = GHOSTTY_CELL_WIDE_NARROW
            if ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) == GHOSTTY_SUCCESS {
                switch wide {
                case GHOSTTY_CELL_WIDE_WIDE: width = .wide
                case GHOSTTY_CELL_WIDE_SPACER_TAIL: width = .spacerTail
                case GHOSTTY_CELL_WIDE_SPACER_HEAD: width = .spacerHead
                default: width = .narrow
                }
            }
        }

        var count = 0
        var result = ghostty_grid_ref_graphemes(&ref, &codepoints, codepoints.count, &count)
        if result == GHOSTTY_OUT_OF_SPACE {
            codepoints = [UInt32](repeating: 0, count: max(count, codepoints.count * 2))
            result = ghostty_grid_ref_graphemes(&ref, &codepoints, codepoints.count, &count)
        }
        guard result == GHOSTTY_SUCCESS, count > 0 else {
            return ScreenNormalizer.Cell(text: "", width: width)
        }
        var scalars = String.UnicodeScalarView()
        for value in codepoints.prefix(count) {
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        return ScreenNormalizer.Cell(text: String(scalars), width: width)
    }
}
