import AppKit
import CoreText
import Metal
import QuartzCore
import TerminalCore

/// `CAMetalLayer` を持つサブビュー。イベントは受けず、下の `TerminalView` に渡す。
@MainActor
final class MetalHostView: NSView {
    let metalLayer = CAMetalLayer()
    /// 大きさが変わった（描画先の大きさを合わせる）。
    var onResize: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onResize?()
    }
}

/// Metal による描画（phase5 design D1）。
///
/// 1 フレームを 1 つのコマンドバッファで、次の順に描く。
/// 1. 背景（既定の背景色で消してから、セルの背景・選択・検索の強調）
/// 2. 下層の画像（Kitty Graphics の z < 0）
/// 3. グリフ（アトラスから取り、前景色で着色）
/// 4. 装飾（下線・打ち消し線、カーソル、IME の未確定の文字列、リンクの下線）と上層の画像
///
/// 色の解決（パレット、反転、太字の明るい色、コントラストの補正）は、Core Text と同じくビューの `rowCellColors` で行う。
@MainActor
final class MetalRenderer: TerminalRenderer {
    let kind = TerminalRendererKind.metal
    let context: MetalRenderContext
    let hostView = MetalHostView()
    let atlas = GlyphAtlas()
    private(set) var cellBuffers = CellBuffers()
    private weak var view: TerminalView?

    private var frameNeeded = true
    var onNeedsFrame: (() -> Void)?
    /// 描いたフレームの数（テスト用）。
    private(set) var framesRendered = 0

    private struct ShapeKey: Hashable {
        let text: String
        let font: Int
    }

    struct ShapedGlyph {
        let font: CTFont
        let glyph: CGGlyph
        /// セルの左端（グリフの原点）からのずれ（point）。
        let dx: CGFloat
        let dy: CGFloat
    }

    private var shapeCache: [ShapeKey: [ShapedGlyph]] = [:]
    /// 最後に描いたときのフォントとセルの寸法（変わったらアトラスを作り直す）。
    private var fontsIdentity: ObjectIdentifier?
    private var lastMetrics: CellMetrics?

    private var grayTexture: MTLTexture?
    private var grayPage: ObjectIdentifier?
    private var grayVersion = -1
    private var colorTexture: MTLTexture?
    private var colorPage: ObjectIdentifier?
    private var colorVersion = -1

    /// 画像の世代ごとのテクスチャ（配置で使わなくなったら捨てる。phase5 design D7）。
    private(set) var imageTextures: [UInt64: MTLTexture] = [:]

    /// GPU が使い終わっていないフレームの数を 3 までにする。
    private let inFlight = DispatchSemaphore(value: 3)
    private var instanceBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var nextBuffer = 0

    init(context: MetalRenderContext) {
        self.context = context
        let layer = hostView.metalLayer
        layer.device = context.device
        layer.pixelFormat = MetalRenderContext.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.contentsGravity = .topLeft
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        hostView.onResize = { [weak self] in self?.updateDrawableSize() }
    }

    // MARK: - TerminalRenderer

    func install(in view: TerminalView) {
        self.view = view
        hostView.frame = view.bounds
        hostView.autoresizingMask = [.width, .height]
        view.addSubview(hostView, positioned: .below, relativeTo: nil)
        updateDrawableSize()
        invalidateAll()
    }

    func uninstall() {
        hostView.removeFromSuperview()
        view = nil
    }

    func invalidateAll() {
        cellBuffers.markAllDirty()
        requestFrame()
    }

    func invalidateRows(_ rows: IndexSet) {
        cellBuffers.markDirty(rows)
        requestFrame()
    }

    func invalidate(_ rect: NSRect) {
        requestFrame()
    }

    private func requestFrame() {
        frameNeeded = true
        onNeedsFrame?()
    }

    func layoutChanged() {
        updateDrawableSize()
        invalidateAll()
    }

    var needsFrame: Bool { frameNeeded }

    var knownImageGenerations: Set<UInt64> { Set(imageTextures.keys) }

    func updateImages(_ placements: [ImagePlacement], pixels: [UInt64: ImagePixels]) {
        for (generation, image) in pixels where imageTextures[generation] == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: image.width, height: image.height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .managed
            guard image.width > 0, image.height > 0, let texture = context.device.makeTexture(descriptor: descriptor) else { continue }
            texture.label = "Tabghostty.image"
            image.rgba.withUnsafeBytes { bytes in
                texture.replace(
                    region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: image.width * 4
                )
            }
            imageTextures[generation] = texture
        }
        // 表示しなくなった画像のテクスチャは手放す（描いている途中のフレームはコマンドバッファが持っている）。
        let used = Set(placements.map(\.generation))
        imageTextures = imageTextures.filter { used.contains($0.key) }
        requestFrame()
    }

    @discardableResult
    func renderFrameIfNeeded() -> Bool {
        guard frameNeeded, let view, view.window != nil else { return false }
        let layer = hostView.metalLayer
        guard layer.drawableSize.width >= 1, layer.drawableSize.height >= 1, let drawable = layer.nextDrawable() else {
            return false
        }
        frameNeeded = false
        encodeFrame(into: drawable.texture, present: drawable)
        return true
    }

    // MARK: - オフスクリーン（テスト・比較用）

    /// ビューの今の内容を、画面に出さずに描いて画像にする（spec: terminal-rendering「Rendering parity」の比較用）。
    func renderOffscreen() -> NSBitmapImageRep? {
        guard let view else { return nil }
        let scale = view.metrics.scale
        let width = Int((view.bounds.width * scale).rounded())
        let height = Int((view.bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalRenderContext.pixelFormat, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = context.device.makeTexture(descriptor: descriptor) else { return nil }
        guard let commandBuffer = encodeFrame(into: texture, present: nil, synchronize: texture) else { return nil }
        commandBuffer.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // テクスチャの値は sRGB のまま（Core Graphics と同じ）なので、sRGB として読む。
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    // MARK: - 行のインスタンス（CellBuffers）

    /// フォントやセルの寸法が変わったら、アトラスを作り直す（古いグリフは使わない）。
    private func refreshFontsIfNeeded(_ view: TerminalView) {
        let identity = ObjectIdentifier(view.fonts)
        guard identity != fontsIdentity || view.metrics != lastMetrics else { return }
        if fontsIdentity != nil {
            atlas.removeAll()
            shapeCache.removeAll()
        }
        fontsIdentity = identity
        lastMetrics = view.metrics
        cellBuffers.markAllDirty()
    }

    /// dirty の行を作り直す。途中でアトラスが溢れて作り直されたら、全行を作り直す。
    func rebuildRows() {
        guard let view else { return }
        refreshFontsIfNeeded(view)
        cellBuffers.resize(rows: view.rows)
        let geometry = DecorationGeometry(metrics: view.metrics, font: view.fonts.regular)
        for _ in 0..<2 {
            let resets = atlas.resetCount
            cellBuffers.rebuildDirty { buildRow($0, view: view, geometry: geometry) }
            guard atlas.resetCount != resets else { return }
            shapeCache.removeAll()
            cellBuffers.markAllDirty()
        }
    }

    private func buildRow(_ y: Int, view: TerminalView, geometry: DecorationGeometry) -> CellBuffers.Row {
        var row = CellBuffers.Row()
        guard y < view.cells.count else { return row }
        let cells = view.cells[y]
        let metrics = view.metrics
        let scale = metrics.scale
        let padding = GridGeometry.padding
        let rowTop = padding + CGFloat(y) * metrics.height
        let defaultBackground = view.defaultBackground

        var runStart = -1
        var runEnd = -1
        var runColor: ColorRGB?
        func flushBackground() {
            guard let color = runColor else { return }
            row.backgrounds.append(RectInstance(
                rect: pixelRect(
                    CGRect(x: padding + CGFloat(runStart) * metrics.width, y: rowTop,
                           width: CGFloat(runEnd - runStart + 1) * metrics.width, height: metrics.height),
                    scale: scale
                ),
                color: Self.color(color)
            ))
            runColor = nil
        }

        for x in 0..<min(cells.count, view.cols) {
            let cell = cells[x]
            let colors = view.rowCellColors(cell, x: x, y: y)
            // 1. 同じ背景色が続く区間を 1 つの矩形にする。
            if colors.background != defaultBackground {
                if colors.background == runColor, runEnd == x - 1 {
                    runEnd = x
                } else {
                    flushBackground()
                    runColor = colors.background
                    runStart = x
                    runEnd = x
                }
            } else {
                flushBackground()
            }
            // 2. グリフ。
            if cell.width != .spacerTail, cell.width != .spacerHead, !cell.text.isEmpty, !cell.attributes.contains(.invisible) {
                let font = view.fonts.fontForText(cell.text, bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic))
                appendGlyphs(
                    cell.text, font: font, color: colors.foreground, alpha: cell.attributes.contains(.faint) ? 0.5 : 1,
                    column: x, rowTop: rowTop, metrics: metrics, into: &row.glyphs
                )
            }
            // 3. 下線・打ち消し線・上線。
            for line in geometry.lines(for: cell, x: x, y: y, foreground: colors.foreground) {
                appendLine(line, geometry: geometry, into: &row.decorations)
            }
        }
        flushBackground()
        return row
    }

    /// テキスト（1 セルの書記素）のグリフを、セルの位置に置く。
    private func appendGlyphs(
        _ text: String,
        font: CTFont,
        color: ColorRGB,
        alpha: Float,
        column: Int,
        rowTop: CGFloat,
        metrics: CellMetrics,
        into glyphs: inout [GlyphInstance]
    ) {
        let scale = metrics.scale
        let cellLeft = (GridGeometry.padding + CGFloat(column) * metrics.width) * scale
        let baseline = (rowTop + metrics.baselineOffset) * scale
        for shaped in shape(text, font: font) {
            let entry = atlas.entry(glyph: shaped.glyph, font: shaped.font, scale: scale)
            guard !entry.isEmpty else { continue }
            let originX = (cellLeft + shaped.dx * scale).rounded()
            let originY = (baseline - shaped.dy * scale).rounded()
            glyphs.append(GlyphInstance(
                rect: SIMD4(Float(originX) + Float(entry.left), Float(originY) - Float(entry.top), Float(entry.width), Float(entry.height)),
                uv: SIMD4(Float(entry.x), Float(entry.y), Float(entry.width), Float(entry.height)),
                color: entry.isColor ? SIMD4(1, 1, 1, alpha) : Self.color(color, alpha: alpha),
                params: SIMD4(entry.isColor ? 1 : 0, 0, 0, 0)
            ))
        }
    }

    /// 書記素のグリフと、セルの中での位置（Core Text でシェーピングした結果。合字は使わない）。
    func shape(_ text: String, font: CTFont) -> [ShapedGlyph] {
        let key = ShapeKey(text: text, font: atlas.fontID(font))
        if let cached = shapeCache[key] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var shaped: [ShapedGlyph] = []
        var firstX: CGFloat?
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runAttributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = runAttributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            for index in 0..<count {
                // セルの中での相対位置（結合文字など）は保ち、最初のグリフをセルの左端に合わせる（Core Text と同じ）。
                let origin = firstX ?? positions[index].x
                firstX = origin
                shaped.append(ShapedGlyph(font: runFont, glyph: glyphs[index], dx: positions[index].x - origin, dy: positions[index].y))
            }
        }
        shapeCache[key] = shaped
        return shaped
    }

    private func appendLine(_ line: DecorationGeometry.Line, geometry: DecorationGeometry, into rects: inout [RectInstance]) {
        let scale = geometry.metrics.scale
        let color = Self.color(line.color, alpha: Float(line.alpha))
        switch line.style {
        case .solid:
            rects.append(RectInstance(rect: pixelRect(line.rect, scale: scale), color: color))
        case .dotted, .dashed:
            for segment in geometry.dashSegments(line) {
                rects.append(RectInstance(rect: pixelRect(segment, scale: scale), color: color))
            }
        case .curly:
            // 2 次ベジェの制御点を ±振幅にした曲線の、実際の高さは振幅の半分。
            let amplitude = geometry.curlyAmplitude / 2
            let band = CGRect(
                x: line.rect.minX, y: line.rect.midY - amplitude - geometry.thickness,
                width: line.rect.width, height: 2 * (amplitude + geometry.thickness)
            )
            rects.append(RectInstance(
                rect: pixelRect(band, scale: scale),
                color: color,
                params: SIMD4(1, Float(geometry.thickness * scale), Float(amplitude * scale), Float(geometry.cellWidth * scale))
            ))
        }
    }

    // MARK: - 行に依らないもの（カーソル、IME）

    /// 描く順に並べたもの。
    private enum OverlayItem {
        case rects([RectInstance])
        case glyphs([GlyphInstance], clip: CGRect?)
    }

    private func buildOverlay(_ view: TerminalView) -> [OverlayItem] {
        var items: [OverlayItem] = []
        let metrics = view.metrics
        let scale = metrics.scale

        // Command を押している間の、リンクの下線。
        let linkUnderlines = view.hoveredLinkUnderlines()
        if !linkUnderlines.isEmpty {
            items.append(.rects(linkUnderlines.map {
                RectInstance(rect: pixelRect($0.rect, scale: scale), color: Self.color($0.color, alpha: Float($0.alpha)))
            }))
        }

        // カーソル（spec: terminal-rendering「Cursor」）。
        if let cursor = view.visibleCursor {
            let rect = view.cellRect(x: cursor.x, y: cursor.y, width: cursor.span)
            let line = CursorGeometry.lineWidth(scale: scale)
            let color = Self.color(view.cursorColor)
            let parts = CursorGeometry.rects(shape: cursor.shape, cell: rect, line: line)
            items.append(.rects(parts.map { RectInstance(rect: pixelRect($0, scale: scale), color: color) }))
            let cell = view.cells[cursor.y][cursor.x]
            if cursor.shape == .block, !cell.text.isEmpty, !cell.attributes.contains(.invisible) {
                // カーソルの下の文字は、セルの背景色で描く。
                var glyphs: [GlyphInstance] = []
                let font = view.fonts.fontForText(cell.text, bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic))
                appendGlyphs(
                    cell.text, font: font, color: view.cursorTextColor(cell), alpha: 1,
                    column: cursor.x, rowTop: rect.minY, metrics: metrics, into: &glyphs
                )
                items.append(.glyphs(glyphs, clip: rect))
            }
        }

        // IME の未確定の文字列（背景で塗り、文字を描き、下線を付ける）。
        let marked = view.markedTextCells
        if let first = marked.first {
            var backgrounds: [RectInstance] = []
            var glyphs: [GlyphInstance] = []
            var underlines: [RectInstance] = []
            let foreground = view.defaultForeground
            for item in marked {
                let rect = view.cellRect(x: item.x, y: item.y, width: item.width)
                backgrounds.append(RectInstance(rect: pixelRect(rect, scale: scale), color: Self.color(view.defaultBackground)))
                let font = view.fonts.fontForText(item.text, bold: false, italic: false)
                appendGlyphs(item.text, font: font, color: foreground, alpha: 1, column: item.x, rowTop: rect.minY, metrics: metrics, into: &glyphs)
                underlines.append(RectInstance(rect: pixelRect(item.underline(in: rect, scale: scale), scale: scale), color: Self.color(foreground)))
            }
            items.append(.rects(backgrounds))
            items.append(.glyphs(glyphs, clip: view.rowRect(first.y)))
            items.append(.rects(underlines))
        }
        return items
    }

    // MARK: - フレーム

    /// 1 フレームを描く。`present` があれば画面に出す。
    @discardableResult
    private func encodeFrame(into target: MTLTexture, present drawable: CAMetalDrawable?, synchronize: MTLTexture? = nil) -> MTLCommandBuffer? {
        guard let view else { return nil }
        rebuildRows()
        let overlay = buildOverlay(view)
        syncAtlasTextures()

        _ = inFlight.wait(timeout: .now() + .milliseconds(100))
        guard let commandBuffer = context.queue.makeCommandBuffer() else {
            inFlight.signal()
            return nil
        }
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        // インスタンスを 1 つのバッファにつなぐ。
        var layout = BufferLayout()
        let rows = cellBuffers.rows
        let backgrounds = layout.reserve(RectInstance.self, count: cellBuffers.backgroundCount)
        let glyphs = layout.reserve(GlyphInstance.self, count: cellBuffers.glyphCount)
        let decorations = layout.reserve(RectInstance.self, count: cellBuffers.decorationCount)
        let overlayRanges: [BufferLayout.Range] = overlay.map { item in
            switch item {
            case .rects(let rects): return layout.reserve(RectInstance.self, count: rects.count)
            case .glyphs(let glyphs, _): return layout.reserve(GlyphInstance.self, count: glyphs.count)
            }
        }
        // 画像（Kitty Graphics）。テクスチャが画像ごとに違うので、1 つずつ描く。
        let scale = view.metrics.scale
        let images: [(layer: ImageLayer, texture: MTLTexture, instance: ImageInstance, range: BufferLayout.Range)] =
            view.images.compactMap { placement in
                guard let texture = imageTextures[placement.generation] else { return nil }
                let width = Float(texture.width)
                let height = Float(texture.height)
                let instance = ImageInstance(
                    rect: pixelRect(view.imageRect(placement), scale: scale),
                    uv: SIMD4(
                        Float(placement.sourceX) / width, Float(placement.sourceY) / height,
                        Float(placement.sourceWidth) / width, Float(placement.sourceHeight) / height
                    )
                )
                return (placement.layer, texture, instance, layout.reserve(ImageInstance.self, count: 1))
            }
        guard let buffer = instanceBuffer(length: max(layout.length, 256)) else {
            commandBuffer.commit()
            return nil
        }
        let base = buffer.contents()
        var cursor = (backgrounds.offset, glyphs.offset, decorations.offset)
        for row in rows {
            cursor.0 += copy(row.backgrounds, to: base + cursor.0)
            cursor.1 += copy(row.glyphs, to: base + cursor.1)
            cursor.2 += copy(row.decorations, to: base + cursor.2)
        }
        for (item, range) in zip(overlay, overlayRanges) {
            switch item {
            case .rects(let rects): _ = copy(rects, to: base + range.offset)
            case .glyphs(let glyphs, _): _ = copy(glyphs, to: base + range.offset)
            }
        }
        for image in images {
            _ = copy([image.instance], to: base + image.range.offset)
        }

        let background = view.defaultBackground
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.r) / 255, green: Double(background.g) / 255, blue: Double(background.b) / 255, alpha: 1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            commandBuffer.commit()
            return nil
        }
        let size = SIMD2<Float>(Float(target.width), Float(target.height))
        var uniforms = size
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(size.x), height: Double(size.y), znear: 0, zfar: 1))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(grayTexture, index: 0)
        encoder.setFragmentTexture(colorTexture, index: 1)

        func drawRects(_ range: BufferLayout.Range) {
            guard range.count > 0 else { return }
            encoder.setRenderPipelineState(context.rectPipeline)
            encoder.setVertexBuffer(buffer, offset: range.offset, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
        }
        func drawGlyphs(_ range: BufferLayout.Range, clip: CGRect? = nil) {
            guard range.count > 0, grayTexture != nil, colorTexture != nil else { return }
            encoder.setRenderPipelineState(context.glyphPipeline)
            encoder.setFragmentTexture(grayTexture, index: 0)
            encoder.setFragmentTexture(colorTexture, index: 1)
            encoder.setVertexBuffer(buffer, offset: range.offset, index: 1)
            if let clip, let scissor = scissorRect(clip, scale: view.metrics.scale, target: target) {
                encoder.setScissorRect(scissor)
            }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: range.count)
            if clip != nil {
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
            }
        }

        func drawImages(_ layer: ImageLayer) {
            let drawn = images.filter { $0.layer == layer }
            guard !drawn.isEmpty else { return }
            encoder.setRenderPipelineState(context.imagePipeline)
            if let scissor = scissorRect(view.gridRect, scale: scale, target: target) {
                encoder.setScissorRect(scissor)
            }
            for image in drawn {
                encoder.setVertexBuffer(buffer, offset: image.range.offset, index: 1)
                encoder.setFragmentTexture(image.texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            }
            encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height))
        }

        // 1. 背景 → 2. 下層の画像 → 3. グリフ → 4. 装飾（行の線）と上層の画像、カーソル、IME。
        drawImages(.belowBackground)
        drawRects(backgrounds)
        drawImages(.belowText)
        drawGlyphs(glyphs)
        drawRects(decorations)
        drawImages(.aboveText)
        for (item, range) in zip(overlay, overlayRanges) {
            switch item {
            case .rects: drawRects(range)
            case .glyphs(_, let clip): drawGlyphs(range, clip: clip)
            }
        }
        encoder.endEncoding()

        if let synchronize, synchronize.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: synchronize)
            blit.endEncoding()
        }
        if let drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        framesRendered += 1
        return commandBuffer
    }

    private struct BufferLayout {
        struct Range {
            var offset: Int
            var count: Int
        }

        private(set) var length = 0

        mutating func reserve<T>(_ type: T.Type, count: Int) -> Range {
            // 頂点バッファのオフセットは 16 バイトの倍数にする（float4 の並び）。
            length = (length + 15) & ~15
            let range = Range(offset: length, count: count)
            length += MemoryLayout<T>.stride * count
            return range
        }
    }

    private func copy<T>(_ items: [T], to pointer: UnsafeMutableRawPointer) -> Int {
        guard !items.isEmpty else { return 0 }
        let bytes = MemoryLayout<T>.stride * items.count
        items.withUnsafeBytes { source in
            pointer.copyMemory(from: source.baseAddress!, byteCount: bytes)
        }
        return bytes
    }

    /// 使い回すインスタンスのバッファ（GPU が使い終わったものを順に使う）。
    private func instanceBuffer(length: Int) -> MTLBuffer? {
        let index = nextBuffer
        nextBuffer = (nextBuffer + 1) % instanceBuffers.count
        if let buffer = instanceBuffers[index], buffer.length >= length {
            return buffer
        }
        // 足りなければ、余裕を持たせて作り直す。
        let buffer = context.device.makeBuffer(length: max(length * 3 / 2, 64 * 1024), options: .storageModeShared)
        buffer?.label = "Tabghostty.instances"
        instanceBuffers[index] = buffer
        return buffer
    }

    // MARK: - アトラスのテクスチャ

    private func syncAtlasTextures() {
        sync(atlas.grayscale, format: .r8Unorm, texture: &grayTexture, page: &grayPage, version: &grayVersion)
        sync(atlas.color, format: .bgra8Unorm, texture: &colorTexture, page: &colorPage, version: &colorVersion)
    }

    private func sync(
        _ atlasPage: AtlasPage,
        format: MTLPixelFormat,
        texture: inout MTLTexture?,
        page: inout ObjectIdentifier?,
        version: inout Int
    ) {
        let identity = ObjectIdentifier(atlasPage)
        let bytesPerRow = atlasPage.width * atlasPage.bytesPerPixel
        if texture == nil || page != identity || version != atlasPage.sizeVersion {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: atlasPage.width, height: atlasPage.height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .managed
            guard let made = context.device.makeTexture(descriptor: descriptor) else { return }
            made.label = format == .r8Unorm ? "Tabghostty.atlas.gray" : "Tabghostty.atlas.color"
            atlasPage.pixels.withUnsafeBytes { bytes in
                made.replace(
                    region: MTLRegionMake2D(0, 0, atlasPage.width, atlasPage.height), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow
                )
            }
            texture = made
            page = identity
            version = atlasPage.sizeVersion
            atlasPage.clearDirty()
            return
        }
        guard let dirty = atlasPage.dirtyRect, let texture else { return }
        atlasPage.pixels.withUnsafeBytes { bytes in
            let start = bytes.baseAddress! + (dirty.y * atlasPage.width + dirty.x) * atlasPage.bytesPerPixel
            texture.replace(
                region: MTLRegionMake2D(dirty.x, dirty.y, dirty.width, dirty.height), mipmapLevel: 0,
                withBytes: start, bytesPerRow: bytesPerRow
            )
        }
        atlasPage.clearDirty()
    }

    // MARK: - 座標と色

    private func updateDrawableSize() {
        guard let view else { return }
        let scale = view.metrics.scale
        let layer = hostView.metalLayer
        layer.contentsScale = scale
        let size = CGSize(width: (hostView.bounds.width * scale).rounded(), height: (hostView.bounds.height * scale).rounded())
        if layer.drawableSize != size, size.width >= 1, size.height >= 1 {
            layer.drawableSize = size
        }
        requestFrame()
    }

    private func pixelRect(_ rect: CGRect, scale: CGFloat) -> SIMD4<Float> {
        SIMD4(Float(rect.minX * scale), Float(rect.minY * scale), Float(rect.width * scale), Float(rect.height * scale))
    }

    private func scissorRect(_ rect: CGRect, scale: CGFloat, target: MTLTexture) -> MTLScissorRect? {
        let minX = max(0, Int((rect.minX * scale).rounded(.down)))
        let minY = max(0, Int((rect.minY * scale).rounded(.down)))
        let maxX = min(target.width, Int((rect.maxX * scale).rounded(.up)))
        let maxY = min(target.height, Int((rect.maxY * scale).rounded(.up)))
        guard maxX > minX, maxY > minY else { return nil }
        return MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func color(_ color: ColorRGB, alpha: Float = 1) -> SIMD4<Float> {
        SIMD4(Float(color.r) / 255, Float(color.g) / 255, Float(color.b) / 255, alpha)
    }
}
