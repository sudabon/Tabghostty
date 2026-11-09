import GhosttyVt

/// 画像を描く層（libghostty の `GhosttyImageLayer`。Kitty Graphics の z の値で決まる）。
public enum ImageLayer: Int, Sendable, Comparable {
    /// セルの背景より下（z < INT32_MIN / 2）。
    case belowBackground = 0
    /// セルの背景より上、文字より下（z < 0）。
    case belowText = 1
    /// 文字より上（z ≥ 0）。
    case aboveText = 2

    public static func < (lhs: ImageLayer, rhs: ImageLayer) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// viewport の中の画像の配置 1 つ（spec: inline-images「Kitty graphics protocol」、phase5 design D7）。
///
/// 値は RenderState（`ghostty_render_state_image_*`）から読んだもの。ピクセルの値は、`ghostty_terminal_resize` に渡した
/// セルの大きさ（device pixel）にもとづく。
public struct ImagePlacement: Equatable, Sendable {
    public var imageID: UInt32
    /// 画像の中身の世代。中身が変わるたびに変わり、ほかの画像・端末とも重ならない（テクスチャのキャッシュのキー）。
    public var generation: UInt64
    public var layer: ImageLayer
    /// 同じ層の中で描く順（小さいものから）。
    public var z: Int32
    /// 左上のセル（viewport の座標。上や左にはみ出すと負になる）。
    public var column: Int
    public var row: Int
    /// 左上のセルの角からのずれ（px）。
    public var offsetX: Int
    public var offsetY: Int
    /// 描く大きさ（px）。
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// 画像のうち描く部分（画像の px）。
    public var sourceX: Int
    public var sourceY: Int
    public var sourceWidth: Int
    public var sourceHeight: Int
}

/// 画像の中身（straight alpha の RGBA8、上の行から順）。
public struct ImagePixels: Equatable, Sendable {
    public var generation: UInt64
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]
}

/// RenderState から画像の配置を読み、まだビューが持っていない画像の中身を Kitty Graphics の保存領域から読む。
/// `RenderStateReader` が持ち、同じ actor の中で使う。
final class ImagePlacementReader {
    private let iterator: GhosttyRenderStateImageIterator

    init() throws {
        var iterator: GhosttyRenderStateImageIterator?
        try VTTerminal.check(ghostty_render_state_image_iterator_new(nil, &iterator), "ghostty_render_state_image_iterator_new")
        guard let iterator else {
            throw VTError(function: "ghostty_render_state_image_iterator_new", code: GHOSTTY_INVALID_VALUE.rawValue)
        }
        self.iterator = iterator
    }

    deinit {
        ghostty_render_state_image_iterator_free(iterator)
    }

    /// 最後の更新で見つかった配置（層、z の順に並べる）と、`known` に無い世代の画像の中身。
    func read(state: GhosttyRenderState, terminal: GhosttyTerminal, known: Set<UInt64>) -> ([ImagePlacement], [UInt64: ImagePixels]) {
        var handle: GhosttyRenderStateImageIterator? = iterator
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &handle) == GHOSTTY_SUCCESS else {
            return ([], [:])
        }
        var placements: [ImagePlacement] = []
        while ghostty_render_state_image_iterator_next(iterator) {
            var proto = GHOSTTY_IMAGE_PROTOCOL_KITTY
            guard get(GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL, &proto), proto == GHOSTTY_IMAGE_PROTOCOL_KITTY else { continue }
            var id: UInt32 = 0
            var generation: UInt64 = 0
            var layer = GHOSTTY_IMAGE_LAYER_ABOVE_TEXT
            var z: Int32 = 0
            var column: Int32 = 0
            var row: Int32 = 0
            var offsetX: UInt32 = 0
            var offsetY: UInt32 = 0
            var width: UInt32 = 0
            var height: UInt32 = 0
            var sourceX: UInt32 = 0
            var sourceY: UInt32 = 0
            var sourceWidth: UInt32 = 0
            var sourceHeight: UInt32 = 0
            guard get(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID, &id),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, &generation),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER, &layer),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_Z, &z),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL, &column),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW, &row),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X, &offsetX),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y, &offsetY),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH, &width),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT, &height),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X, &sourceX),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y, &sourceY),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH, &sourceWidth),
                  get(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT, &sourceHeight),
                  width > 0, height > 0, sourceWidth > 0, sourceHeight > 0 else { continue }
            placements.append(ImagePlacement(
                imageID: id, generation: generation, layer: ImageLayer(rawValue: Int(layer.rawValue)) ?? .aboveText, z: z,
                column: Int(column), row: Int(row), offsetX: Int(offsetX), offsetY: Int(offsetY),
                pixelWidth: Int(width), pixelHeight: Int(height),
                sourceX: Int(sourceX), sourceY: Int(sourceY), sourceWidth: Int(sourceWidth), sourceHeight: Int(sourceHeight)
            ))
        }
        placements.sort { ($0.layer, $0.z) < ($1.layer, $1.z) }

        var pixels: [UInt64: ImagePixels] = [:]
        let missing = placements.filter { !known.contains($0.generation) }
        if !missing.isEmpty {
            var graphics: GhosttyKittyGraphics?
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS, let graphics {
                for placement in missing where pixels[placement.generation] == nil {
                    if let image = Self.pixels(of: placement.imageID, in: graphics, generation: placement.generation) {
                        pixels[placement.generation] = image
                    }
                }
            }
        }
        return (placements, pixels)
    }

    private func get<T>(_ data: GhosttyRenderStateImageData, _ value: inout T) -> Bool {
        ghostty_render_state_image_get(iterator, data, &value) == GHOSTTY_SUCCESS
    }

    /// 画像の中身を RGBA8 にして返す（libghostty は RGB / RGBA / グレー / グレーと alpha で持つ。PNG は展開済み）。
    static func pixels(of id: UInt32, in graphics: GhosttyKittyGraphics, generation: UInt64) -> ImagePixels? {
        guard let image = ghostty_kitty_graphics_image(graphics, id) else { return nil }
        var width: UInt32 = 0
        var height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var data = GhosttyString()
        guard ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &width) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT, &height) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT, &format) == GHOSTTY_SUCCESS,
              ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &data) == GHOSTTY_SUCCESS,
              let pointer = data.ptr, width > 0, height > 0 else { return nil }
        let count = Int(width) * Int(height)
        let source = UnsafeBufferPointer(start: pointer, count: data.len)
        var rgba = [UInt8](repeating: 255, count: count * 4)
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            guard source.count >= count * 4 else { return nil }
            rgba.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: source.baseAddress!, count: count * 4) }
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            guard source.count >= count * 3 else { return nil }
            for index in 0..<count {
                rgba[index * 4] = source[index * 3]
                rgba[index * 4 + 1] = source[index * 3 + 1]
                rgba[index * 4 + 2] = source[index * 3 + 2]
            }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA:
            guard source.count >= count * 2 else { return nil }
            for index in 0..<count {
                let gray = source[index * 2]
                rgba[index * 4] = gray
                rgba[index * 4 + 1] = gray
                rgba[index * 4 + 2] = gray
                rgba[index * 4 + 3] = source[index * 2 + 1]
            }
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY:
            guard source.count >= count else { return nil }
            for index in 0..<count {
                rgba[index * 4] = source[index]
                rgba[index * 4 + 1] = source[index]
                rgba[index * 4 + 2] = source[index]
            }
        default:
            return nil
        }
        return ImagePixels(generation: generation, width: Int(width), height: Int(height), rgba: rgba)
    }
}

extension VTTerminal {
    /// Kitty Graphics の画像の保存領域の上限（1 つの画面ごと）。libghostty の既定は 10 MB で、Retina の
    /// スクリーンショット（RGBA に展開すると 20 MB ほど）が入らないので広げる（phase5 design D7）。
    public static let kittyImageStorageLimit: UInt64 = 64 * 1024 * 1024

    /// Kitty Graphics の保存領域の上限を設定する。Kitty Graphics を使えないビルドなら false。
    @discardableResult
    func configureKittyGraphics() -> Bool {
        var limit = Self.kittyImageStorageLimit
        return ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit) == GHOSTTY_SUCCESS
    }

    /// Kitty Graphics の保存領域にある画像の中身（テスト・デバッグ用）。
    public func kittyImage(id: UInt32) -> ImagePixels? {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS, let graphics else {
            return nil
        }
        return ImagePlacementReader.pixels(of: id, in: graphics, generation: 0)
    }
}
