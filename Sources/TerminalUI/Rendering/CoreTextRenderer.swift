import AppKit
import CoreText
import TerminalCore

/// Core Text / Core Graphics による描画（Phase 1 の描画。phase5 design D1）。
///
/// ビューの `draw(_:)` から呼ばれ、AppKit が渡す変わった矩形だけを描く。変化はビューの `setNeedsDisplay` で知らせる。
/// Metal の描画との比較（spec: terminal-rendering「Rendering parity」）と、Metal が使えないときの退避先に使う。
@MainActor
final class CoreTextRenderer: TerminalRenderer {
    let kind = TerminalRendererKind.coreText
    /// AppKit が描くので使わない。
    var onNeedsFrame: (() -> Void)?
    private weak var view: TerminalView?
    private var colorCache: [RGBAKey: CGColor] = [:]
    /// 画像の世代ごとの CGImage（配置で使わなくなったら捨てる）。
    private var imageCache: [UInt64: CGImage] = [:]

    private struct RGBAKey: Hashable {
        let color: ColorRGB
        let alpha: CGFloat
    }

    func install(in view: TerminalView) {
        self.view = view
        view.needsDisplay = true
    }

    func uninstall() {
        view = nil
    }

    func invalidateAll() {
        view?.needsDisplay = true
    }

    func invalidateRows(_ rows: IndexSet) {
        guard let view else { return }
        for y in rows {
            view.setNeedsDisplay(view.rowRect(y))
        }
    }

    func invalidate(_ rect: NSRect) {
        view?.setNeedsDisplay(rect)
    }

    func layoutChanged() {
        view?.needsDisplay = true
    }

    /// AppKit の再描画を待つだけなので、display link で描くものは無い。
    var needsFrame: Bool { false }

    func renderFrameIfNeeded() -> Bool { false }

    var knownImageGenerations: Set<UInt64> { Set(imageCache.keys) }

    func updateImages(_ placements: [ImagePlacement], pixels: [UInt64: ImagePixels]) {
        for (generation, image) in pixels where imageCache[generation] == nil {
            if let made = Self.makeImage(image) { imageCache[generation] = made }
        }
        let used = Set(placements.map(\.generation))
        imageCache = imageCache.filter { used.contains($0.key) }
    }

    /// straight alpha の RGBA8 から CGImage を作る。
    private static func makeImage(_ pixels: ImagePixels) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels.rgba) as CFData) else { return nil }
        return CGImage(
            width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - 描画（phase1 design D6）

    func draw(dirtyRects: [NSRect], in context: CGContext) {
        guard let view else { return }
        let background = view.defaultBackground
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        // 下から順に: 既定の背景 → 背景より下の画像 → セルの背景 → 文字より下の画像 → 文字と線 → 文字より上の画像。
        for rect in dirtyRects {
            context.setFillColor(cgColor(background))
            context.fill(rect)
        }
        drawImages(.belowBackground, dirtyRects: dirtyRects, view: view, context: context)
        for rect in dirtyRects {
            drawCells(in: rect, pass: .backgrounds, view: view, context: context)
        }
        drawImages(.belowText, dirtyRects: dirtyRects, view: view, context: context)
        for rect in dirtyRects {
            drawCells(in: rect, pass: .text, view: view, context: context)
        }
        drawImages(.aboveText, dirtyRects: dirtyRects, view: view, context: context)
        // Command を押している間の、リンクの下線。
        let geometry = DecorationGeometry(metrics: view.metrics, font: view.fonts.regular)
        for line in view.hoveredLinkUnderlines() where dirtyRects.contains(where: { $0.intersects(line.rect) }) {
            drawLine(line, geometry: geometry, context: context)
        }
        drawCursor(dirtyRects: dirtyRects, view: view, context: context)
        drawMarkedText(dirtyRects: dirtyRects, view: view, context: context)
    }

    private enum CellPass {
        case backgrounds, text
    }

    private func drawCells(in dirtyRect: NSRect, pass: CellPass, view: TerminalView, context: CGContext) {
        // 描画の範囲がビューより大きく渡されることがある（オフスクリーンの描画など）。行・列に直す前に bounds に収める。
        let rect = dirtyRect.intersection(view.bounds)
        let metrics = view.metrics
        let padding = GridGeometry.padding
        guard view.rows > 0, view.cols > 0, !rect.isNull, !rect.isEmpty else { return }
        let firstRow = max(0, Int(((rect.minY - padding) / metrics.height).rounded(.down)))
        let lastRow = min(view.rows - 1, Int(((rect.maxY - padding) / metrics.height).rounded(.up)))
        // 2 セル幅の文字が範囲の手前から始まることがあるので、1 セル広げる。
        let firstCol = max(0, Int(((rect.minX - padding) / metrics.width).rounded(.down)) - 1)
        let lastCol = min(view.cols - 1, Int(((rect.maxX - padding) / metrics.width).rounded(.up)))
        guard firstRow <= lastRow, firstCol <= lastCol else { return }

        context.saveGState()
        context.clip(to: rect)
        for y in firstRow...lastRow {
            switch pass {
            case .backgrounds: drawRowBackground(y, columns: firstCol...lastCol, view: view, context: context)
            case .text: drawRowText(y, columns: firstCol...lastCol, view: view, context: context)
            }
        }
        context.restoreGState()
    }

    /// 1. 同じ背景色が続く区間ごとに塗る（選択と検索の強調は、セルの背景色として解決済み）。
    private func drawRowBackground(_ y: Int, columns: ClosedRange<Int>, view: TerminalView, context: CGContext) {
        let row = view.cells[y]
        let metrics = view.metrics
        let padding = GridGeometry.padding
        let resolved = columns.map { view.rowCellColors(row[$0], x: $0, y: y) }
        let rowTop = padding + CGFloat(y) * metrics.height

        var start = columns.lowerBound
        while start <= columns.upperBound {
            let color = resolved[start - columns.lowerBound].background
            var end = start
            while end + 1 <= columns.upperBound, resolved[end + 1 - columns.lowerBound].background == color {
                end += 1
            }
            if color != view.defaultBackground {
                context.setFillColor(cgColor(color))
                context.fill(NSRect(
                    x: padding + CGFloat(start) * metrics.width, y: rowTop,
                    width: CGFloat(end - start + 1) * metrics.width, height: metrics.height
                ))
            }
            start = end + 1
        }
    }

    /// 2. 同じスタイルが続く区間ごとにグリフを描き、3. 線を引く。
    private func drawRowText(_ y: Int, columns: ClosedRange<Int>, view: TerminalView, context: CGContext) {
        let row = view.cells[y]
        let metrics = view.metrics
        let padding = GridGeometry.padding
        let resolved = columns.map { view.rowCellColors(row[$0], x: $0, y: y) }
        let rowTop = padding + CGFloat(y) * metrics.height

        // 2. 同じスタイルが続く区間ごとにグリフを描く。
        var run: [Int] = []
        var runKey: TextRunKey?
        func flush() {
            if let runKey, !run.isEmpty {
                drawText(run.map { row[$0] }, columns: run, key: runKey, rowTop: rowTop, view: view, context: context)
            }
            run.removeAll(keepingCapacity: true)
        }
        for x in columns {
            let cell = row[x]
            guard cell.width != .spacerTail, cell.width != .spacerHead, !cell.text.isEmpty,
                  !cell.attributes.contains(.invisible) else {
                flush()
                runKey = nil
                continue
            }
            let key = TextRunKey(
                font: view.fonts.fontForText(cell.text, bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic)),
                color: resolved[x - columns.lowerBound].foreground,
                faint: cell.attributes.contains(.faint)
            )
            if key != runKey {
                flush()
                runKey = key
            }
            run.append(x)
        }
        flush()

        // 3. 下線・打ち消し線・上線。
        let geometry = DecorationGeometry(metrics: metrics, font: view.fonts.regular)
        for x in columns {
            let cell = row[x]
            let colors = resolved[x - columns.lowerBound]
            for line in geometry.lines(for: cell, x: x, y: y, foreground: colors.foreground) {
                drawLine(line, geometry: geometry, context: context)
            }
        }
    }

    struct TextRunKey: Equatable {
        let font: CTFont
        let color: ColorRGB
        let faint: Bool

        static func == (lhs: TextRunKey, rhs: TextRunKey) -> Bool {
            lhs.font == rhs.font && lhs.color == rhs.color && lhs.faint == rhs.faint
        }
    }

    /// 1 つのスタイルの区間を描く。グリフは、そのグリフの元の文字があるセルの位置に置く（グリッドからずれない）。
    private func drawText(
        _ runCells: [CellSnapshot],
        columns: [Int],
        key: TextRunKey,
        rowTop: CGFloat,
        view: TerminalView,
        context: CGContext
    ) {
        var text = ""
        var columnForUTF16: [Int] = []
        for (cell, column) in zip(runCells, columns) {
            text += cell.text
            columnForUTF16.append(contentsOf: repeatElement(column, count: cell.text.utf16.count))
        }
        guard !text.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): key.font,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.setFillColor(cgColor(key.color, alpha: key.faint ? 0.5 : 1))
        let metrics = view.metrics
        let padding = GridGeometry.padding
        let baseline = rowTop + metrics.baselineOffset

        for glyphRun in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(glyphRun)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(glyphRun, range, &glyphs)
            CTRunGetPositions(glyphRun, range, &positions)
            CTRunGetStringIndices(glyphRun, range, &indices)
            let runAttributes = CTRunGetAttributes(glyphRun) as NSDictionary
            let runFont = runAttributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? key.font

            // セルの中での相対位置（結合文字など）は保ち、セルの先頭はグリッドに合わせる。
            //
            // CTFontDrawGlyphs の位置はテキスト空間の座標で、テキスト行列（上下を反転している。`draw`）を通して
            // ビューの座標になる。ビューの y（下向き）を渡すとビューの外（上）に描かれてしまうので、y の符号を反転して渡す。
            var cellOrigin: [Int: CGFloat] = [:]
            var placed = [CGPoint](repeating: .zero, count: count)
            for index in 0..<count {
                let utf16Index = min(max(0, indices[index]), columnForUTF16.count - 1)
                let column = columnForUTF16[utf16Index]
                let origin = cellOrigin[column] ?? positions[index].x
                cellOrigin[column] = origin
                let viewY = baseline - positions[index].y
                placed[index] = CGPoint(
                    x: padding + CGFloat(column) * metrics.width + (positions[index].x - origin),
                    y: -viewY
                )
            }
            CTFontDrawGlyphs(runFont, glyphs, placed, count, context)
        }
    }

    private func drawLine(_ line: DecorationGeometry.Line, geometry: DecorationGeometry, context: CGContext) {
        let color = cgColor(line.color, alpha: line.alpha)
        context.setFillColor(color)
        context.setStrokeColor(color)
        let rect = line.rect
        let thickness = geometry.thickness
        switch line.style {
        case .solid:
            context.fill(rect)
        case .curly:
            let amplitude = geometry.curlyAmplitude
            let y = rect.minY + thickness / 2
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: y))
            let step = geometry.cellWidth / 2
            var position = rect.minX
            var up = true
            while position < rect.maxX {
                let next = min(position + step, rect.maxX)
                path.addQuadCurve(
                    to: CGPoint(x: next, y: y),
                    control: CGPoint(x: (position + next) / 2, y: y + (up ? -amplitude : amplitude))
                )
                position = next
                up.toggle()
            }
            context.setLineWidth(thickness)
            context.addPath(path)
            context.strokePath()
        case .dotted, .dashed:
            context.saveGState()
            context.setLineWidth(thickness)
            context.setLineDash(phase: 0, lengths: line.style == .dotted ? geometry.dotPattern : geometry.dashPattern)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: - 画像（spec: inline-images「Kitty graphics protocol」）

    private func drawImages(_ layer: ImageLayer, dirtyRects: [NSRect], view: TerminalView, context: CGContext) {
        let placements = view.images.filter { $0.layer == layer }
        guard !placements.isEmpty else { return }
        let grid = view.gridRect
        for placement in placements {
            let rect = view.imageRect(placement)
            guard dirtyRects.contains(where: { $0.intersects(rect) }), let image = imageCache[placement.generation] else { continue }
            let source = CGRect(x: placement.sourceX, y: placement.sourceY, width: placement.sourceWidth, height: placement.sourceHeight)
            guard let cropped = source == CGRect(x: 0, y: 0, width: image.width, height: image.height)
                ? image : image.cropping(to: source) else { continue }
            context.saveGState()
            context.clip(to: grid)
            // ビューは上下が反転しているので、画像は反転し直して描く。
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }

    // MARK: - カーソル（spec: terminal-rendering「Cursor」）

    private func drawCursor(dirtyRects: [NSRect], view: TerminalView, context: CGContext) {
        guard let cursor = view.visibleCursor else { return }
        let rect = view.cellRect(x: cursor.x, y: cursor.y, width: cursor.span)
        guard dirtyRects.contains(where: { $0.intersects(rect) }) else { return }
        let cell = view.cells[cursor.y][cursor.x]
        let color = view.cursorColor
        let line = CursorGeometry.lineWidth(scale: view.metrics.scale)

        context.saveGState()
        context.clip(to: rect)
        switch cursor.shape {
        case .block:
            context.setFillColor(cgColor(color))
            context.fill(rect)
            // カーソルの下の文字は、セルの背景色で描く。
            if !cell.text.isEmpty, !cell.attributes.contains(.invisible) {
                let key = TextRunKey(
                    font: view.fonts.fontForText(cell.text, bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic)),
                    color: view.cursorTextColor(cell),
                    faint: false
                )
                drawText([cell], columns: [cursor.x], key: key, rowTop: rect.minY, view: view, context: context)
            }
        case .underline, .bar, .hollowBlock:
            context.setFillColor(cgColor(color))
            for part in CursorGeometry.rects(shape: cursor.shape, cell: rect, line: line) {
                context.fill(part)
            }
        }
        context.restoreGState()
    }

    // MARK: - IME の未確定の文字列（spec: terminal-input「Input method composition」）

    /// 未確定の文字列をカーソルの位置に重ねて描く（背景で塗り、下線を付ける。選ばれている文節は太い下線）。
    private func drawMarkedText(dirtyRects: [NSRect], view: TerminalView, context: CGContext) {
        let layout = view.markedTextCells
        guard let first = layout.first else { return }
        let rowArea = view.rowRect(first.y)
        guard dirtyRects.contains(where: { $0.intersects(rowArea) }) else { return }

        let foreground = view.defaultForeground
        context.saveGState()
        context.clip(to: rowArea)
        for item in layout {
            let rect = view.cellRect(x: item.x, y: item.y, width: item.width)
            context.setFillColor(cgColor(view.defaultBackground))
            context.fill(rect)

            var cell = CellSnapshot.blank
            cell.text = item.text
            cell.width = item.width == 2 ? .wide : .narrow
            let key = TextRunKey(font: view.fonts.fontForText(item.text, bold: false, italic: false), color: foreground, faint: false)
            drawText([cell], columns: [item.x], key: key, rowTop: rect.minY, view: view, context: context)

            context.setFillColor(cgColor(foreground))
            context.fill(item.underline(in: rect, scale: view.metrics.scale))
        }
        context.restoreGState()
    }

    // MARK: - 色

    private func cgColor(_ color: ColorRGB, alpha: CGFloat = 1) -> CGColor {
        let key = RGBAKey(color: color, alpha: alpha)
        if let cached = colorCache[key] { return cached }
        let value = CGColor(
            srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: alpha
        )
        colorCache[key] = value
        return value
    }
}
