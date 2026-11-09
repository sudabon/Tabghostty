import AppKit
import CoreText
import TerminalCore

/// セルの寸法（design D5）。
public struct CellMetrics: Equatable, Sendable {
    /// 画面の倍率（`backingScaleFactor`）。
    public var scale: CGFloat
    /// セルの幅・高さ（device pixel）。
    public var widthPx: Int
    public var heightPx: Int
    /// フォントの ascent（point）。ベースラインはセルの上端からこの分だけ下（行間の半分を足す）。
    public var ascent: CGFloat
    public var descent: CGFloat
    public var leading: CGFloat

    /// セルの幅・高さ（point）。
    public var width: CGFloat { CGFloat(widthPx) / scale }
    public var height: CGFloat { CGFloat(heightPx) / scale }

    /// セルの上端からベースラインまで（point）。余った高さは上下に半分ずつ配る。
    public var baselineOffset: CGFloat {
        let extra = max(0, height - (ascent + descent + leading))
        return ((extra + leading) / 2 + ascent).rounded(.toNearestOrAwayFromZero, scale: scale)
    }

    /// 文字の大きさから求める。幅は `M` の advance、高さは ascent + descent + leading。
    /// どちらも device pixel に切り上げる（グリフが欠けないように）。
    public static func make(advance: CGFloat, ascent: CGFloat, descent: CGFloat, leading: CGFloat, scale: CGFloat) -> CellMetrics {
        let scale = max(scale, 1)
        let widthPx = max(1, Int((advance * scale - 0.001).rounded(.up)))
        let heightPx = max(1, Int(((ascent + descent + leading) * scale - 0.001).rounded(.up)))
        return CellMetrics(scale: scale, widthPx: widthPx, heightPx: heightPx, ascent: ascent, descent: descent, leading: leading)
    }

    /// フォントから求める。
    public static func make(font: NSFont, scale: CGFloat) -> CellMetrics {
        let ctFont = font as CTFont
        var glyph: CGGlyph = 0
        var character: UniChar = 0x4D // "M"
        var advance = CGSize.zero
        if CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1) {
            CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &glyph, &advance, 1)
        }
        if advance.width <= 0 {
            advance.width = font.maximumAdvancement.width
        }
        return make(
            advance: advance.width,
            ascent: CTFontGetAscent(ctFont),
            descent: CTFontGetDescent(ctFont),
            leading: CTFontGetLeading(ctFont),
            scale: scale
        )
    }
}

/// ビューの大きさとグリッドの大きさの対応（spec: terminal-rendering「Grid size follows the view」）。
public enum GridGeometry {
    /// ビューの内側の余白（point）。
    public static let padding: CGFloat = 4
    /// リサイズのデバウンス。
    public static let debounce: Duration = .milliseconds(50)

    /// `floor((view - 2×4pt) / cell)`。最小 1×1。
    public static func gridSize(viewSize: CGSize, cell: CellMetrics) -> (cols: Int, rows: Int) {
        let width = max(0, viewSize.width - 2 * padding)
        let height = max(0, viewSize.height - 2 * padding)
        let cols = Int((width / cell.width).rounded(.down))
        let rows = Int((height / cell.height).rounded(.down))
        return (max(1, min(cols, Int(UInt16.max))), max(1, min(rows, Int(UInt16.max))))
    }

    /// Terminal に渡すサイズ（セル数と、セルの device pixel）。
    public static func terminalGrid(viewSize: CGSize, cell: CellMetrics) -> TerminalController.GridSize {
        let grid = gridSize(viewSize: viewSize, cell: cell)
        return TerminalController.GridSize(cols: grid.cols, rows: grid.rows, cellWidthPx: cell.widthPx, cellHeightPx: cell.heightPx)
    }

    /// 前回 Terminal に渡したサイズから変わったか。変わっていなければ、Terminal にも PTY にも何もしない。
    public static func needsUpdate(previous: TerminalController.GridSize?, next: TerminalController.GridSize) -> Bool {
        previous != next
    }

    // MARK: - ポインタの位置（spec: terminal-mouse）

    /// ビューの座標（point、左上が原点）を surface 座標（device pixel）にする。
    public static func surfacePosition(_ point: CGPoint, scale: CGFloat) -> (x: Double, y: Double) {
        (Double(point.x * scale), Double(point.y * scale))
    }

    /// ビューの座標（point、左上が原点）の下にあるセル。パディングを除き、グリッドの中に収める。
    public static func cell(at point: CGPoint, cell: CellMetrics, cols: Int, rows: Int) -> GridPoint {
        let column = Int(((point.x - padding) / cell.width).rounded(.down))
        let row = Int(((point.y - padding) / cell.height).rounded(.down))
        return GridPoint(x: min(max(0, column), max(0, cols - 1)), y: min(max(0, row), max(0, rows - 1)))
    }

    /// マウスエンコーダと選択のジェスチャーに渡す、描画領域の大きさ（device pixel）。
    public static func mouseSurface(viewSize: CGSize, cell: CellMetrics, cols: Int, rows: Int) -> MouseSurface {
        let scale = cell.scale
        let width = Int((viewSize.width * scale).rounded())
        let height = Int((viewSize.height * scale).rounded())
        let paddingPx = Int((padding * scale).rounded())
        return MouseSurface(
            width: width,
            height: height,
            cellWidth: cell.widthPx,
            cellHeight: cell.heightPx,
            paddingTop: paddingPx,
            paddingBottom: max(0, height - paddingPx - rows * cell.heightPx),
            paddingLeft: paddingPx,
            paddingRight: max(0, width - paddingPx - cols * cell.widthPx),
            columns: max(1, cols)
        )
    }
}

extension CGFloat {
    /// device pixel の境界に丸める。
    func rounded(_ rule: FloatingPointRoundingRule, scale: CGFloat) -> CGFloat {
        (self * scale).rounded(rule) / scale
    }
}
