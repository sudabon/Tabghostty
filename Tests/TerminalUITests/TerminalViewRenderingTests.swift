import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: terminal-rendering「Cell drawing」。ビューをオフスクリーンで描き、セルの位置にグリフが描かれることを確かめる。
@MainActor
@Suite struct TerminalViewRenderingTests {
    private struct Rendered {
        let image: NSBitmapImageRep
        let metrics: CellMetrics
        let background: ColorRGB

        /// セル（列・行）の範囲で、`matches` を満たすピクセルの数。
        func count(col: Int, row: Int, width: Int = 1, _ matches: (ColorRGB) -> Bool) -> Int {
            let scale = metrics.scale
            let x0 = Int(((GridGeometry.padding + CGFloat(col) * metrics.width) * scale).rounded())
            let y0 = Int(((GridGeometry.padding + CGFloat(row) * metrics.height) * scale).rounded())
            var total = 0
            for y in y0..<(y0 + metrics.heightPx) {
                for x in x0..<(x0 + metrics.widthPx * width) {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let rgb = ColorRGB(
                        r: UInt8((color.redComponent * 255).rounded()),
                        g: UInt8((color.greenComponent * 255).rounded()),
                        b: UInt8((color.blueComponent * 255).rounded())
                    )
                    if matches(rgb) { total += 1 }
                }
            }
            return total
        }

        func inked(col: Int, row: Int, width: Int = 1) -> Int {
            count(col: col, row: row, width: width) { distance($0, background) > 60 }
        }
    }

    private nonisolated static func distance(_ a: ColorRGB, _ b: ColorRGB) -> Int {
        abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))
    }

    private func render(_ text: String, palette: Palette) async throws -> Rendered {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", cols: 40, rows: 4, maxScrollback: 10, colors: palette.terminalColors, sink: sink)
        await controller.attach()
        await controller.receiveReplay(Array(text.utf8), done: true)

        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: palette)
        view.controller = controller
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        view.apply(try #require(await controller.makeSnapshot(forceFull: true)))
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        // オフスクリーンの描画では、ビューより大きな範囲が渡される（それでも落ちない）。
        view.cacheDisplay(in: view.bounds, to: image)
        return Rendered(image: image, metrics: view.metrics, background: palette.background)
    }

    @Test(arguments: ["light", "dark"])
    func glyphsAreDrawnInTheirCells(scheme: String) async throws {
        let palette: Palette = scheme == "light" ? .light : .dark
        let rendered = try await render("ab  cd\r\nx", palette: palette)
        // 1 行目（カーソルは 2 行目にある）の文字のセルにはインクがあり、空白のセルには無い。
        #expect(rendered.inked(col: 0, row: 0) > 10)
        #expect(rendered.inked(col: 1, row: 0) > 10)
        #expect(rendered.inked(col: 2, row: 0) == 0)
        #expect(rendered.inked(col: 3, row: 0) == 0)
        #expect(rendered.inked(col: 4, row: 0) > 10)
        #expect(rendered.inked(col: 10, row: 0) == 0)
    }

    // Scenario: SGR colors
    @Test func sgrColorIsUsed() async throws {
        let rendered = try await render("ok \u{1b}[31mRRR\u{1b}[0m", palette: .light)
        let red = ColorRGB(hex: 0xcc0000)
        #expect(rendered.count(col: 3, row: 0, width: 3) { Self.distance($0, red) < 40 } > 20)
        #expect(rendered.count(col: 0, row: 0, width: 2) { Self.distance($0, red) < 40 } == 0)
    }

    // Scenario: Wide characters（「が」が 2 セル、「a」は 3 セル目）
    @Test func wideCharacterSpansTwoCells() async throws {
        let rendered = try await render("がa\r\n", palette: .dark)
        #expect(rendered.inked(col: 0, row: 0, width: 2) > 20)
        #expect(rendered.inked(col: 2, row: 0) > 10)
        #expect(rendered.inked(col: 3, row: 0) == 0)
    }
}
