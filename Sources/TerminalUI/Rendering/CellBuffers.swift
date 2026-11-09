import Foundation
import simd

/// 矩形 1 つ（`MetalShaders` の `RectInstance` と同じ並び）。
struct RectInstance: Equatable {
    /// x, y, w, h（device pixel）
    var rect: SIMD4<Float>
    /// sRGB の r, g, b, a（straight alpha）
    var color: SIMD4<Float>
    /// x: 0 = 塗りつぶし、1 = 波線。y: 線の太さ、z: 振幅、w: 周期（px）
    var params: SIMD4<Float> = .zero
}

/// グリフ 1 つ（`MetalShaders` の `GlyphInstance` と同じ並び）。
struct GlyphInstance: Equatable {
    /// x, y, w, h（device pixel）
    var rect: SIMD4<Float>
    /// アトラスの x, y, w, h（px）
    var uv: SIMD4<Float>
    /// モノクロは前景色。カラーは a だけを使う
    var color: SIMD4<Float>
    /// x: 0 = モノクロ、1 = カラー
    var params: SIMD4<Float>
}

/// 画像 1 つ（`MetalShaders` の `ImageInstance` と同じ並び）。
struct ImageInstance: Equatable {
    var rect: SIMD4<Float>
    /// テクスチャの x, y, w, h（0〜1）
    var uv: SIMD4<Float>
}

/// 行ごとのインスタンス（phase5 design D1 の `CellBuffers`）。
///
/// 行の内容（セル、選択、検索の強調）が変わった行だけを作り直す。1 フレームで描くときは、全行をつないで GPU に送る
/// （つなぐのはコピーだけなので軽い。重いのは色の解決とグリフの検索・ラスタライズで、それは dirty の行だけで行う）。
struct CellBuffers {
    struct Row: Equatable {
        /// 既定の背景色と違う背景（選択と検索の強調を含む）。
        var backgrounds: [RectInstance] = []
        var glyphs: [GlyphInstance] = []
        /// 下線・打ち消し線・上線。
        var decorations: [RectInstance] = []
    }

    private(set) var rows: [Row] = []
    private(set) var dirty = IndexSet()

    var rowCount: Int { rows.count }

    /// 行数を合わせる。変わったら全行を作り直す。
    mutating func resize(rows count: Int) {
        guard count != rows.count else { return }
        rows = Array(repeating: Row(), count: count)
        dirty = IndexSet(integersIn: 0..<count)
    }

    mutating func markDirty(_ indices: IndexSet) {
        for index in indices where index >= 0 && index < rows.count {
            dirty.insert(index)
        }
    }

    mutating func markAllDirty() {
        dirty = IndexSet(integersIn: 0..<rows.count)
    }

    /// dirty の行だけを `build` で作り直す。作り直した行を返す。
    @discardableResult
    mutating func rebuildDirty(_ build: (Int) -> Row) -> IndexSet {
        let rebuilt = dirty
        for index in rebuilt {
            rows[index] = build(index)
        }
        dirty.removeAll()
        return rebuilt
    }

    var backgroundCount: Int { rows.reduce(0) { $0 + $1.backgrounds.count } }
    var glyphCount: Int { rows.reduce(0) { $0 + $1.glyphs.count } }
    var decorationCount: Int { rows.reduce(0) { $0 + $1.decorations.count } }
}
