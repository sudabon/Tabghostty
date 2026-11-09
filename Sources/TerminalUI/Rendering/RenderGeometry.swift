import AppKit
import CoreText
import TerminalCore

/// 下線・打ち消し線・上線の位置と太さ（Core Text と Metal で同じ値を使う。spec: terminal-rendering「Rendering parity」）。
struct DecorationGeometry {
    enum Style: Equatable {
        case solid, curly, dotted, dashed
    }

    /// 1 本の線。`rect` は線の帯（ビューの座標、point）。破線・波線は帯の中央を通る線として描く。
    struct Line: Equatable {
        var rect: CGRect
        var style: Style
        var color: ColorRGB
        var alpha: CGFloat
    }

    let metrics: CellMetrics
    /// 線の太さ（point。device pixel に丸める）。
    let thickness: CGFloat
    private let underlinePosition: CGFloat
    private let xHeight: CGFloat

    init(metrics: CellMetrics, font: NSFont) {
        self.metrics = metrics
        let ctFont = font as CTFont
        thickness = max(1 / metrics.scale, CTFontGetUnderlineThickness(ctFont).rounded(.toNearestOrAwayFromZero, scale: metrics.scale))
        underlinePosition = CTFontGetUnderlinePosition(ctFont)
        xHeight = CTFontGetXHeight(ctFont)
    }

    var cellWidth: CGFloat { metrics.width }
    var curlyAmplitude: CGFloat { max(thickness, metrics.height * 0.06) }
    var dotPattern: [CGFloat] { [thickness, thickness * 2] }
    var dashPattern: [CGFloat] { [metrics.width * 0.4, metrics.width * 0.2] }

    /// 行 `y` の下線の帯の上端（device pixel に合わせる。Core Text と Metal で同じ位置になるように）。
    func underlineTop(rowTop: CGFloat) -> CGFloat {
        let baseline = rowTop + metrics.baselineOffset
        let top = min(rowTop + metrics.height - thickness, baseline - underlinePosition + thickness / 2)
        return top.rounded(.toNearestOrAwayFromZero, scale: metrics.scale)
    }

    /// セル 1 つの線。線が無ければ空。
    func lines(for cell: CellSnapshot, x: Int, y: Int, foreground: ColorRGB) -> [Line] {
        guard cell.width != .spacerTail, !cell.attributes.contains(.invisible),
              cell.underline != .none || cell.attributes.contains(.strikethrough) || cell.attributes.contains(.overline) else {
            return []
        }
        let rowTop = GridGeometry.padding + CGFloat(y) * metrics.height
        let left = GridGeometry.padding + CGFloat(x) * metrics.width
        let width = CGFloat(cell.width == .wide ? 2 : 1) * metrics.width
        let alpha: CGFloat = cell.attributes.contains(.faint) ? 0.5 : 1
        var lines: [Line] = []

        if cell.underline != .none {
            let color = cell.underlineColor ?? foreground
            let top = underlineTop(rowTop: rowTop)
            func band(_ y: CGFloat) -> CGRect { CGRect(x: left, y: y, width: width, height: thickness) }
            switch cell.underline {
            case .none:
                break
            case .single:
                lines.append(Line(rect: band(top), style: .solid, color: color, alpha: alpha))
            case .double:
                lines.append(Line(rect: band(top - thickness), style: .solid, color: color, alpha: alpha))
                lines.append(Line(rect: band(top + thickness), style: .solid, color: color, alpha: alpha))
            case .curly:
                // 波線は下線の上端を中心に描く（Phase 1 と同じ）。
                lines.append(Line(rect: band(top - thickness / 2), style: .curly, color: color, alpha: alpha))
            case .dotted:
                lines.append(Line(rect: band(top), style: .dotted, color: color, alpha: alpha))
            case .dashed:
                lines.append(Line(rect: band(top), style: .dashed, color: color, alpha: alpha))
            }
        }
        if cell.attributes.contains(.strikethrough) {
            let strikeY = (rowTop + metrics.baselineOffset - xHeight / 2).rounded(.toNearestOrAwayFromZero, scale: metrics.scale)
            let strikeTop = (strikeY - thickness / 2).rounded(.toNearestOrAwayFromZero, scale: metrics.scale)
            lines.append(Line(
                rect: CGRect(x: left, y: strikeTop, width: width, height: thickness),
                style: .solid, color: foreground, alpha: alpha
            ))
        }
        if cell.attributes.contains(.overline) {
            lines.append(Line(
                rect: CGRect(x: left, y: rowTop, width: width, height: thickness),
                style: .solid, color: foreground, alpha: alpha
            ))
        }
        return lines
    }

    /// 点線・破線を、塗りつぶす矩形に分ける（Metal で描くのに使う。Core Text の破線と同じ周期）。
    func dashSegments(_ line: Line) -> [CGRect] {
        let pattern = line.style == .dotted ? dotPattern : dashPattern
        guard pattern.count == 2, pattern[0] > 0, pattern[0] + pattern[1] > 0 else { return [line.rect] }
        var segments: [CGRect] = []
        var x = line.rect.minX
        let scale = metrics.scale
        while x < line.rect.maxX {
            let start = x.rounded(.toNearestOrAwayFromZero, scale: scale)
            let end = min(x + pattern[0], line.rect.maxX).rounded(.toNearestOrAwayFromZero, scale: scale)
            if end > start {
                segments.append(CGRect(x: start, y: line.rect.minY, width: end - start, height: line.rect.height))
            }
            x += pattern[0] + pattern[1]
        }
        return segments
    }
}

/// カーソルの形ごとの塗る矩形（spec: terminal-rendering「Cursor」）。
enum CursorGeometry {
    /// 線の太さ（1 point を device pixel に丸める）。
    static func lineWidth(scale: CGFloat) -> CGFloat {
        max(1 / scale, (1 as CGFloat).rounded(.toNearestOrAwayFromZero, scale: scale))
    }

    /// `cell` はカーソルのセル（2 セル幅の文字なら 2 セル分）。
    static func rects(shape: CursorShape, cell rect: NSRect, line: CGFloat) -> [NSRect] {
        switch shape {
        case .block:
            return [rect]
        case .underline:
            return [NSRect(x: rect.minX, y: rect.maxY - 2 * line, width: rect.width, height: 2 * line)]
        case .bar:
            return [NSRect(x: rect.minX, y: rect.minY, width: 2 * line, height: rect.height)]
        case .hollowBlock:
            return [
                NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: line),
                NSRect(x: rect.minX, y: rect.maxY - line, width: rect.width, height: line),
                NSRect(x: rect.minX, y: rect.minY + line, width: line, height: rect.height - 2 * line),
                NSRect(x: rect.maxX - line, y: rect.minY + line, width: line, height: rect.height - 2 * line),
            ]
        }
    }
}

/// IME の未確定の文字列を置くセル 1 つ。
struct MarkedTextCell: Equatable {
    var text: String
    var x: Int
    var y: Int
    var width: Int
    /// 変換中の文節（太い下線）。
    var isSelected: Bool

    /// 下線の矩形（`rect` はこのセルの矩形）。
    func underline(in rect: NSRect, scale: CGFloat) -> NSRect {
        let thickness = CursorGeometry.lineWidth(scale: scale)
        let height = isSelected ? thickness * 2 : thickness
        return NSRect(x: rect.minX, y: rect.maxY - height - thickness, width: rect.width, height: height)
    }
}

extension TerminalView {
    /// 行 `y` の列 `x` のセルを描く色（セルの色に、検索の強調と選択の色を重ねたもの）。
    func rowCellColors(_ cell: CellSnapshot, x: Int, y: Int) -> ResolvedColors {
        var colors = resolveColors(cell)
        if let highlight = searchHighlightKind(x: x, y: y) {
            // 検索の一致は背景を塗り、文字は読める色に補正する（spec: terminal-search）。
            let background = highlight == .current ? palette.searchCurrentMatch : palette.searchMatch
            colors.foreground = contrastAdjusted(colors.foreground, on: background)
            colors.background = background
        }
        if y < rowSelections.count, let selected = rowSelections[y], selected.contains(x) {
            // 選択範囲は配色の選択色で塗る（文字の色はそのまま）。
            colors.background = palette.selection
        }
        return colors
    }

    /// ブロックカーソルの下の文字の色（セルの背景色）。
    func cursorTextColor(_ cell: CellSnapshot) -> ColorRGB {
        resolveColors(cell).background
    }
}
