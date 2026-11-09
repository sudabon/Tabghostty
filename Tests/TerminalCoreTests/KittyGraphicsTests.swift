import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TerminalCore

/// spec: inline-images「Kitty graphics protocol」「Unsupported image protocols」、phase5 design D7。
@Suite struct KittyGraphicsTests {
    /// 2×2 の RGBA（赤、緑、青、半透明の白）。
    private static let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128]

    private func terminal() throws -> VTTerminal {
        // セルは 10×20 px（Retina の 2 倍なら 20×40 px）。
        try VTTerminal(cols: 20, rows: 6, maxScrollback: 100, cellWidthPx: 10, cellHeightPx: 20)
    }

    private func kitty(_ control: String, _ payload: [UInt8] = []) -> [UInt8] {
        bytes("\u{1b}_G\(control);\(Data(payload).base64EncodedString())\u{1b}\\")
    }

    private static func pngData(width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) { pixels[index * 4] = 200; pixels[index * 4 + 3] = 255 }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return Array(data as Data)
    }

    // 転送して表示すると、画像と配置が取れる。
    @Test func transmittedImageAndPlacementAreAvailable() throws {
        let terminal = try terminal()
        terminal.write(bytes("ab"))
        terminal.write(kitty("a=T,f=32,s=2,v=2,i=7", Self.rgba))
        let image = try #require(terminal.kittyImage(id: 7))
        #expect(image.width == 2 && image.height == 2)
        #expect(image.rgba == Self.rgba)

        let snapshot = try terminal.makeSnapshot(forceFull: true)
        let placement = try #require(snapshot.images.first)
        #expect(snapshot.images.count == 1)
        #expect(placement.imageID == 7)
        // カーソルの位置（3 列目）に、画像の大きさ（px）で置く。
        #expect(placement.column == 2 && placement.row == 0)
        #expect(placement.pixelWidth == 2 && placement.pixelHeight == 2)
        #expect(placement.sourceWidth == 2 && placement.sourceHeight == 2)
        #expect(placement.layer == .aboveText)
        #expect(placement.generation != 0)
        #expect(snapshot.imagePixels[placement.generation]?.rgba == Self.rgba)

        // ビューが持っている世代の中身は、もう一度は渡さない。
        let next = try terminal.makeSnapshot(forceFull: true, knownImageGenerations: [placement.generation])
        #expect(next.images == snapshot.images)
        #expect(next.imagePixels.isEmpty)
    }

    // セルの数を指定すると、セルの大きさ（device pixel）に合わせて描く大きさが決まる（Retina でも同じ見た目）。
    @Test(arguments: [(10, 20), (20, 40)])
    func sizeFollowsTheCellPixelSize(cell: (Int, Int)) throws {
        let terminal = try VTTerminal(cols: 20, rows: 6, maxScrollback: 100, cellWidthPx: cell.0, cellHeightPx: cell.1)
        terminal.write(kitty("a=T,f=32,s=2,v=2,i=1,c=4,r=2,C=1", Self.rgba))
        let placement = try #require(try terminal.makeSnapshot(forceFull: true).images.first)
        #expect(placement.pixelWidth == 4 * cell.0)
        #expect(placement.pixelHeight == 2 * cell.1)
    }

    @Test func pngIsDecodedToRGBA() throws {
        let terminal = try terminal()
        terminal.write(kitty("a=T,f=100,i=3", try Self.pngData(width: 30, height: 12)))
        let snapshot = try terminal.makeSnapshot(forceFull: true)
        let placement = try #require(snapshot.images.first)
        let pixels = try #require(snapshot.imagePixels[placement.generation])
        #expect(pixels.width == 30 && pixels.height == 12)
        #expect(pixels.rgba[0] == 200 && pixels.rgba[3] == 255)
    }

    @Test func negativeZGoesBelowText() throws {
        let terminal = try terminal()
        terminal.write(kitty("a=T,f=32,s=2,v=2,i=1,z=-1", Self.rgba))
        terminal.write(kitty("a=T,f=32,s=2,v=2,i=2,z=-1073741825", Self.rgba))
        terminal.write(kitty("a=T,f=32,s=2,v=2,i=3,z=5", Self.rgba))
        let layers = try terminal.makeSnapshot(forceFull: true).images.map(\.layer)
        // 層の順に並ぶ。
        #expect(layers == [.belowBackground, .belowText, .aboveText])
    }

    // 削除すると配置が無くなる。
    @Test func deletedPlacementsDisappear() throws {
        let terminal = try terminal()
        terminal.write(kitty("a=T,f=32,s=2,v=2,i=7", Self.rgba))
        #expect(try terminal.makeSnapshot(forceFull: true).images.count == 1)
        terminal.write(bytes("\u{1b}_Ga=d,d=A\u{1b}\\"))
        #expect(try terminal.makeSnapshot(forceFull: true).images.isEmpty)
    }

    // Scenario: Scrolled away — 画面の外に流れても、スクロールバックで元の位置に戻る。
    @Test func placementsScrollWithTheText() throws {
        let terminal = try terminal()
        terminal.write(bytes("top\r\n"))
        terminal.write(kitty("a=T,f=32,s=2,v=2,i=7", Self.rgba))
        terminal.write(bytes((0..<20).map { "\r\nline \($0)" }.joined()))
        #expect(try terminal.makeSnapshot(forceFull: true).images.isEmpty)
        terminal.scrollViewport(by: -terminal.viewportOffset)
        let placement = try #require(try terminal.makeSnapshot(forceFull: true).images.first)
        #expect(placement.row == 1 && placement.column == 0)
    }

    // MARK: - Sixel / iTerm2 IIP（spec: inline-images「Unsupported image protocols」）

    private func screenText(_ terminal: VTTerminal) throws -> [String] {
        try terminal.makeSnapshot(forceFull: true).dirtyRows.map { $0.cells.map(\.text).joined() }
    }

    // Scenario: Sixel — 画像は出ず、ゴミも残らず、`done` がその位置に出る。
    @Test func sixelIsIgnoredWithoutDebris() throws {
        let terminal = try terminal()
        terminal.write(bytes("before\r\n\u{1b}Pq#0;2;0;0;0#1;2;100;100;0#1~~@@vv@@~~@@~~$#2??}}GG}}??}}??-\u{1b}\\done"))
        let text = try screenText(terminal)
        #expect(text[0] == "before")
        #expect(text[1] == "done")
        #expect(text.dropFirst(2).allSatisfy { $0.isEmpty })
        #expect(try terminal.makeSnapshot(forceFull: true).images.isEmpty)
        let cursor = try #require(try terminal.makeSnapshot(forceFull: true).cursor)
        #expect(cursor.x == 4 && cursor.y == 1)
    }

    @Test func iterm2InlineImagesAreIgnoredWithoutDebris() throws {
        let terminal = try terminal()
        let png = Data(try Self.pngData(width: 4, height: 4)).base64EncodedString()
        terminal.write(bytes("x\u{1b}]1337;File=name=dGVzdA==;size=\(png.count);inline=1:\(png)\u{07}done\r\n"))
        // ST で終わる形も。
        terminal.write(bytes("\u{1b}]1337;File=inline=1:\(png)\u{1b}\\next"))
        let text = try screenText(terminal)
        #expect(text[0] == "xdone")
        #expect(text[1] == "next")
        #expect(try terminal.makeSnapshot(forceFull: true).images.isEmpty)
    }
}
