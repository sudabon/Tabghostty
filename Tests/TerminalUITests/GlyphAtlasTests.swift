import AppKit
import CoreText
import Testing
@testable import TerminalUI

/// phase5 design D1: グリフのアトラス（棚詰め、R8 と BGRA8、(font, glyph, scale) のキー）。
@Suite struct GlyphAtlasTests {
    private func glyph(_ character: Character, in font: CTFont) -> CGGlyph {
        let utf16 = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        _ = CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        return glyphs[0]
    }

    private let menlo = CTFontCreateWithName("Menlo" as CFString, 14, nil)

    @Test func shelfPackerPlacesRectanglesOnShelvesWithoutOverlap() {
        var packer = ShelfPacker(width: 32, height: 32, spacing: 1)
        var placed: [CGRect] = []
        for _ in 0..<12 {
            guard let origin = packer.allocate(width: 7, height: 9) else { break }
            placed.append(CGRect(x: origin.x, y: origin.y, width: 7, height: 9))
        }
        // 1 段に 4 つ（7+1 = 8 px ずつ）、3 段まで（9+1 = 10 px ずつ）。
        #expect(placed.count == 12)
        for (index, rect) in placed.enumerated() {
            #expect(rect.maxX <= 32 && rect.maxY <= 32)
            for other in placed[(index + 1)...] {
                #expect(!rect.intersects(other))
            }
        }
        #expect(packer.allocate(width: 7, height: 9) == nil)
        // 広げると、置いた位置はそのままで、残りに置ける。
        packer.grow(width: 64, height: 32)
        #expect(packer.allocate(width: 7, height: 9) != nil)
        #expect(packer.shelves.count == 3)
    }

    @Test func sameGlyphIsRasterizedOnceAndReused() {
        let atlas = GlyphAtlas(initialSize: 128)
        let a = glyph("a", in: menlo)
        let first = atlas.entry(glyph: a, font: menlo, scale: 2)
        let second = atlas.entry(glyph: a, font: menlo, scale: 2)
        #expect(first == second)
        #expect(atlas.rasterizeCount == 1)
        #expect(atlas.count == 1)
        #expect(!first.isEmpty && !first.isColor)
        // 倍率が違えば別のグリフ（device pixel の大きさが違う）。
        let retina1x = atlas.entry(glyph: a, font: menlo, scale: 1)
        #expect(atlas.rasterizeCount == 2)
        #expect(retina1x.width < first.width)
        // カバレッジが書き込まれている。
        let inked = (0..<first.height).contains { y in
            (0..<first.width).contains { x in atlas.grayscale.value(x: first.x + x, y: first.y + y) > 128 }
        }
        #expect(inked)
    }

    @Test func blankGlyphsHaveNothingToDraw() {
        let atlas = GlyphAtlas(initialSize: 64)
        let space = atlas.entry(glyph: glyph(" ", in: menlo), font: menlo, scale: 2)
        #expect(space.isEmpty)
        #expect(atlas.grayscale.dirtyRect == nil)
    }

    @Test func overflowingGlyphsGrowTheAtlasAndKeepEarlierOnes() {
        let atlas = GlyphAtlas(initialSize: 32, maximumSize: 1024)
        let first = atlas.entry(glyph: glyph("A", in: menlo), font: menlo, scale: 2)
        let firstPixels = (0..<first.height).map { y in
            (0..<first.width).map { x in atlas.grayscale.value(x: first.x + x, y: first.y + y) }
        }
        let versionBefore = atlas.grayscale.sizeVersion
        for character in "BCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" {
            _ = atlas.entry(glyph: glyph(character, in: menlo), font: menlo, scale: 2)
        }
        #expect(atlas.grayscale.width * atlas.grayscale.height > 32 * 32)
        #expect(atlas.grayscale.sizeVersion > versionBefore)
        #expect(atlas.resetCount == 0)
        // 広げても、先に置いたグリフの位置と中身は変わらない。
        #expect(atlas.entry(glyph: glyph("A", in: menlo), font: menlo, scale: 2) == first)
        let after = (0..<first.height).map { y in
            (0..<first.width).map { x in atlas.grayscale.value(x: first.x + x, y: first.y + y) }
        }
        #expect(after == firstPixels)
    }

    @Test func atlasStartsOverWhenTheMaximumSizeIsReached() {
        let atlas = GlyphAtlas(initialSize: 32, maximumSize: 64)
        for character in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" {
            let entry = atlas.entry(glyph: glyph(character, in: menlo), font: menlo, scale: 2)
            #expect(!entry.isEmpty)
        }
        #expect(atlas.resetCount > 0)
        #expect(atlas.grayscale.width <= 64 && atlas.grayscale.height <= 64)
    }

    @Test func colorEmojiGoesToTheColorPage() throws {
        let base = menlo
        let emoji = "😀"
        let font = CTFontCreateForString(base, emoji as CFString, CFRange(location: 0, length: (emoji as NSString).length))
        #expect(CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs))
        let utf16 = Array(emoji.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        _ = CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
        let atlas = GlyphAtlas(initialSize: 128)
        let entry = atlas.entry(glyph: glyphs[0], font: font, scale: 2)
        #expect(entry.isColor)
        #expect(!entry.isEmpty)
        #expect(atlas.color.dirtyRect != nil)
        #expect(atlas.grayscale.dirtyRect == nil)
        // BGRA の alpha（4 バイト目）が入っている。
        let opaque = (0..<entry.height).contains { y in
            (0..<entry.width).contains { x in atlas.color.value(x: entry.x + x, y: entry.y + y, channel: 3) > 200 }
        }
        #expect(opaque)
    }
}
