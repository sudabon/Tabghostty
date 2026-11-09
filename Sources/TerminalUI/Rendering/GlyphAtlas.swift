import CoreGraphics
import CoreText

/// 棚詰め（shelf packing）で矩形を置く（phase5 design D1）。
///
/// 高さの近い矩形を同じ棚（横に並べる帯）に置く。置けなければ新しい棚を下に開く。
/// `grow` で大きくしても、置いた矩形の位置は変わらない（幅を広げると既存の棚が右に伸び、高さを広げると下に棚を開ける）。
struct ShelfPacker: Equatable {
    struct Shelf: Equatable {
        var y: Int
        var height: Int
        var nextX: Int
    }

    private(set) var width: Int
    private(set) var height: Int
    private(set) var shelves: [Shelf] = []
    /// 矩形の間に空ける隙間（テクスチャを補間して読んでも隣のグリフがにじまないように）。
    let spacing: Int

    init(width: Int, height: Int, spacing: Int = 1) {
        self.width = width
        self.height = height
        self.spacing = spacing
    }

    private var nextShelfY: Int {
        shelves.last.map { $0.y + $0.height + spacing } ?? 0
    }

    /// `w`×`h` の矩形を置く場所。置けなければ nil（大きくしてから置き直す）。
    mutating func allocate(width w: Int, height h: Int) -> (x: Int, y: Int)? {
        guard w > 0, h > 0, w <= width, h <= height else { return nil }
        // 高さが足りて、無駄の少ない（高さの近い）棚を選ぶ。
        var best: Int?
        for index in shelves.indices {
            let shelf = shelves[index]
            guard shelf.height >= h, shelf.nextX + w <= width else { continue }
            // 半分以下の高さの矩形を高い棚に置くと無駄が多いので、新しい棚を開けられるならそちらにする。
            if shelf.height > h * 2, nextShelfY + h <= height { continue }
            if let current = best, shelves[current].height <= shelf.height { continue }
            best = index
        }
        if let best {
            let x = shelves[best].nextX
            shelves[best].nextX += w + spacing
            return (x, shelves[best].y)
        }
        let y = nextShelfY
        guard y + h <= height else { return nil }
        shelves.append(Shelf(y: y, height: h, nextX: w + spacing))
        return (0, y)
    }

    /// 大きくする（小さくはしない）。置いた矩形の位置はそのまま。
    mutating func grow(width newWidth: Int, height newHeight: Int) {
        width = max(width, newWidth)
        height = max(height, newHeight)
    }
}

/// アトラスの 1 枚（R8 のモノクロ、または BGRA8 のカラー）。CPU 側にピクセルを持ち、GPU へはまとめて送る。
final class AtlasPage {
    /// 1 ピクセルのバイト数（R8 は 1、BGRA8 は 4）。
    let bytesPerPixel: Int
    private(set) var packer: ShelfPacker
    private(set) var pixels: [UInt8]
    /// 大きさが変わるたびに増える（テクスチャを作り直す）。
    private(set) var sizeVersion = 0
    /// GPU に送っていない範囲（大きさが変わったら全体）。
    private(set) var dirtyRect: (x: Int, y: Int, width: Int, height: Int)?

    var width: Int { packer.width }
    var height: Int { packer.height }

    init(width: Int, height: Int, bytesPerPixel: Int) {
        self.bytesPerPixel = bytesPerPixel
        packer = ShelfPacker(width: width, height: height)
        pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    }

    func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        packer.allocate(width: width, height: height)
    }

    /// 大きくする（中身はそのまま左上に残す）。
    func grow(width newWidth: Int, height newHeight: Int) {
        let oldWidth = width
        let oldHeight = height
        packer.grow(width: newWidth, height: newHeight)
        var next = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        let oldRow = oldWidth * bytesPerPixel
        let newRow = width * bytesPerPixel
        pixels.withUnsafeBufferPointer { source in
            next.withUnsafeMutableBufferPointer { destination in
                for y in 0..<oldHeight {
                    let from = source.baseAddress! + y * oldRow
                    let to = destination.baseAddress! + y * newRow
                    to.update(from: from, count: oldRow)
                }
            }
        }
        pixels = next
        sizeVersion += 1
        dirtyRect = (0, 0, width, height)
    }

    /// `bitmap`（上の行から順、1 行 `bytesPerRow` バイト）を (x, y) に書き込む。
    func write(_ bitmap: UnsafeRawBufferPointer, bytesPerRow: Int, x: Int, y: Int, width w: Int, height h: Int) {
        let rowBytes = w * bytesPerPixel
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<h {
                let from = bitmap.baseAddress! + row * bytesPerRow
                let to = destination.baseAddress! + ((y + row) * width + x) * bytesPerPixel
                to.copyMemory(from: from, byteCount: rowBytes)
            }
        }
        markDirty(x: x, y: y, width: w, height: h)
    }

    /// (x, y) のピクセルの値（テスト用。BGRA8 なら先頭のバイト）。
    func value(x: Int, y: Int, channel: Int = 0) -> UInt8 {
        pixels[(y * width + x) * bytesPerPixel + channel]
    }

    /// GPU に送ったので、送っていない範囲を空にする。
    func clearDirty() {
        dirtyRect = nil
    }

    private func markDirty(x: Int, y: Int, width w: Int, height h: Int) {
        guard let current = dirtyRect else {
            dirtyRect = (x, y, w, h)
            return
        }
        let minX = min(current.x, x)
        let minY = min(current.y, y)
        let maxX = max(current.x + current.width, x + w)
        let maxY = max(current.y + current.height, y + h)
        dirtyRect = (minX, minY, maxX - minX, maxY - minY)
    }
}

/// グリフのアトラス（phase5 design D1）。
///
/// - グリフは Core Text で 1 つずつラスタライズする。モノクロのグリフは R8（カバレッジ）、カラー絵文字は
///   BGRA8（premultiplied）のページに置く。
/// - キーは (フォント, グリフ, 画面の倍率)。同じキーは一度だけラスタライズして使い回す。
/// - 棚詰めで置き、溢れたら倍に広げる（`maximumSize` まで）。それでも溢れたら全部を捨てて作り直す
///   （`resetCount` が増える。描画の実装は全行を作り直す）。
final class GlyphAtlas {
    struct Key: Hashable {
        let font: Int
        let glyph: CGGlyph
        /// 画面の倍率 × 100。
        let scale: Int
    }

    /// アトラスの中のグリフ 1 つ。
    struct Entry: Equatable {
        /// アトラスの中の位置と大きさ（px）。大きさが 0 なら描くものが無い（空白など）。
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        /// グリフの原点（ベースライン上）から、ビットマップの左端までの距離（px。右が正）。
        var left: Int
        /// グリフの原点から、ビットマップの上端までの距離（px。上が正）。
        var top: Int
        /// カラーのページにある（絵文字）。
        var isColor: Bool

        var isEmpty: Bool { width == 0 || height == 0 }
    }

    let initialSize: Int
    let maximumSize: Int
    private(set) var grayscale: AtlasPage
    private(set) var color: AtlasPage
    private var entries: [Key: Entry] = [:]
    private var fontIDs: [CTFont: Int] = [:]
    private var fonts: [CTFont] = []
    /// 溢れて全部を捨てた回数。
    private(set) var resetCount = 0
    /// ラスタライズした回数（テスト用）。
    private(set) var rasterizeCount = 0

    /// グリフのまわりに空ける余白（px。アンチエイリアスのにじみを切らないように）。
    static let padding = 1

    init(initialSize: Int = 512, maximumSize: Int = 8192) {
        self.initialSize = initialSize
        self.maximumSize = max(initialSize, maximumSize)
        grayscale = AtlasPage(width: initialSize, height: initialSize, bytesPerPixel: 1)
        color = AtlasPage(width: initialSize, height: initialSize, bytesPerPixel: 4)
    }

    var count: Int { entries.count }

    /// フォントの番号（キーに使う）。同じフォントには同じ番号を返す。
    func fontID(_ font: CTFont) -> Int {
        if let id = fontIDs[font] { return id }
        let id = fonts.count
        fonts.append(font)
        fontIDs[font] = id
        return id
    }

    func font(for id: Int) -> CTFont? {
        id < fonts.count ? fonts[id] : nil
    }

    /// グリフの位置。まだ無ければラスタライズしてアトラスに置く。
    func entry(glyph: CGGlyph, font: CTFont, scale: CGFloat) -> Entry {
        let scaleKey = Int((scale * 100).rounded())
        let key = Key(font: fontID(font), glyph: glyph, scale: scaleKey)
        if let cached = entries[key] { return cached }
        let resets = resetCount
        let entry = rasterize(glyph: glyph, font: font, scale: scale)
        // 溢れて全部を捨てたなら、フォントの番号も振り直されている。
        entries[resets == resetCount ? key : Key(font: fontID(font), glyph: glyph, scale: scaleKey)] = entry
        return entry
    }

    /// 全部を捨てる（フォントや倍率が変わって、古いグリフを使わなくなったとき）。
    func removeAll() {
        entries.removeAll()
        fontIDs.removeAll()
        fonts.removeAll()
        grayscale = AtlasPage(width: initialSize, height: initialSize, bytesPerPixel: 1)
        color = AtlasPage(width: initialSize, height: initialSize, bytesPerPixel: 4)
        resetCount += 1
    }

    // MARK: - ラスタライズ

    private func rasterize(glyph: CGGlyph, font: CTFont, scale: CGFloat) -> Entry {
        rasterizeCount += 1
        var glyph = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, &bounds, 1)
        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        guard !bounds.isNull, !bounds.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return Entry(x: 0, y: 0, width: 0, height: 0, left: 0, top: 0, isColor: isColor)
        }
        let pad = Self.padding
        let left = Int((bounds.minX * scale).rounded(.down)) - pad
        let right = Int((bounds.maxX * scale).rounded(.up)) + pad
        let bottom = Int((bounds.minY * scale).rounded(.down)) - pad
        let top = Int((bounds.maxY * scale).rounded(.up)) + pad
        let width = right - left
        let height = top - bottom
        guard width > 0, height > 0, width <= maximumSize, height <= maximumSize else {
            return Entry(x: 0, y: 0, width: 0, height: 0, left: 0, top: 0, isColor: isColor)
        }

        let page = isColor ? color : grayscale
        guard let origin = place(width: width, height: height, in: page) else {
            // 最大の大きさでも置けない。全部を捨てて置き直す（描画の実装は全行を作り直す）。
            removeAll()
            return rasterize(glyph: glyph, font: font, scale: scale)
        }

        let bytesPerPixel = page.bytesPerPixel
        let bytesPerRow = width * bytesPerPixel
        var bitmap = [UInt8](repeating: 0, count: bytesPerRow * height)
        bitmap.withUnsafeMutableBytes { buffer in
            let context: CGContext?
            if isColor {
                context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                )
            } else {
                // カバレッジだけを書く（黒地に白で描いた明るさ。色は描くときに付ける）。
                context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            }
            guard let context else { return }
            context.setShouldAntialias(true)
            context.setAllowsFontSubpixelPositioning(true)
            context.setShouldSubpixelPositionFonts(true)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.translateBy(x: CGFloat(-left), y: CGFloat(-bottom))
            context.scaleBy(x: scale, y: scale)
            var position = CGPoint.zero
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            context.flush()
        }
        bitmap.withUnsafeBytes { buffer in
            page.write(buffer, bytesPerRow: bytesPerRow, x: origin.x, y: origin.y, width: width, height: height)
        }
        return Entry(x: origin.x, y: origin.y, width: width, height: height, left: left, top: top, isColor: isColor)
    }

    /// ページに置く。溢れたら倍に広げる（幅と高さを交互に）。最大でも置けなければ nil。
    private func place(width: Int, height: Int, in page: AtlasPage) -> (x: Int, y: Int)? {
        while true {
            if let origin = page.allocate(width: width, height: height) { return origin }
            guard page.width < maximumSize || page.height < maximumSize else { return nil }
            if page.width <= page.height, page.width < maximumSize {
                page.grow(width: min(maximumSize, page.width * 2), height: page.height)
            } else {
                page.grow(width: page.width, height: min(maximumSize, page.height * 2))
            }
        }
    }
}
