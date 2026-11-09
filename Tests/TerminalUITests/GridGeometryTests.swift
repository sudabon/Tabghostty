import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: terminal-rendering「Grid size follows the view」の純粋関数の部分。
@Suite struct GridGeometryTests {
    @Test func cellSizeIsRoundedUpToDevicePixels() {
        let retina = CellMetrics.make(advance: 8.43, ascent: 11.1, descent: 2.9, leading: 0, scale: 2)
        #expect(retina.widthPx == 17)
        #expect(retina.heightPx == 28)
        #expect(retina.width == 8.5)
        #expect(retina.height == 14)

        let standard = CellMetrics.make(advance: 8.43, ascent: 11.1, descent: 2.9, leading: 0, scale: 1)
        #expect(standard.widthPx == 9)
        #expect(standard.heightPx == 14)

        // ちょうど device pixel の境界にあるときは、そのまま。
        let exact = CellMetrics.make(advance: 8.5, ascent: 12, descent: 4, leading: 1, scale: 2)
        #expect(exact.widthPx == 17)
        #expect(exact.heightPx == 34)
    }

    @Test func menloMetricsAreSane() {
        let font = NSFont(name: "Menlo-Regular", size: 14)!
        let metrics = CellMetrics.make(font: font, scale: 2)
        #expect(metrics.widthPx >= 16 && metrics.widthPx <= 18)
        #expect(metrics.heightPx >= 30 && metrics.heightPx <= 36)
        #expect(metrics.baselineOffset > 0 && metrics.baselineOffset < metrics.height)
    }

    @Test func gridSizeSubtractsPaddingAndFloors() {
        let cell = CellMetrics.make(advance: 8.5, ascent: 12, descent: 4, leading: 1, scale: 2) // 8.5 × 17 pt
        // 幅: (858 - 8) / 8.5 = 100、高さ: (518 - 8) / 17 = 30
        let exact = GridGeometry.gridSize(viewSize: CGSize(width: 858, height: 518), cell: cell)
        #expect(exact.cols == 100)
        #expect(exact.rows == 30)
        // 1 セル未満の端数は切り捨てる。
        let fraction = GridGeometry.gridSize(viewSize: CGSize(width: 866, height: 534), cell: cell)
        #expect(fraction.cols == 100)
        #expect(fraction.rows == 30)
        // 小さすぎても 1×1。
        let tiny = GridGeometry.gridSize(viewSize: CGSize(width: 3, height: 3), cell: cell)
        #expect(tiny.cols == 1)
        #expect(tiny.rows == 1)
    }

    // Scenario: Unchanged grid
    @Test func changesSmallerThanACellDoNotTriggerAResize() {
        let cell = CellMetrics.make(advance: 8.5, ascent: 12, descent: 4, leading: 1, scale: 2)
        let before = GridGeometry.terminalGrid(viewSize: CGSize(width: 858, height: 518), cell: cell)
        let after = GridGeometry.terminalGrid(viewSize: CGSize(width: 863, height: 530), cell: cell)
        #expect(before == after)
        #expect(!GridGeometry.needsUpdate(previous: before, next: after))

        let wider = GridGeometry.terminalGrid(viewSize: CGSize(width: 867, height: 518), cell: cell)
        #expect(wider.cols == 101)
        #expect(GridGeometry.needsUpdate(previous: before, next: wider))
        #expect(GridGeometry.needsUpdate(previous: nil, next: before))
    }

    // Scenario: Display change（セルのピクセルサイズが変わる）
    @Test func scaleChangeChangesCellPixelSize() {
        let font = NSFont(name: "Menlo-Regular", size: 14)!
        let retina = GridGeometry.terminalGrid(viewSize: CGSize(width: 800, height: 600), cell: .make(font: font, scale: 2))
        let standard = GridGeometry.terminalGrid(viewSize: CGSize(width: 800, height: 600), cell: .make(font: font, scale: 1))
        #expect(retina.cellWidthPx > standard.cellWidthPx)
        #expect(retina.cellHeightPx > standard.cellHeightPx)
        #expect(GridGeometry.needsUpdate(previous: retina, next: standard))
    }

    @Test func debounceIsFiftyMilliseconds() {
        #expect(GridGeometry.debounce == .milliseconds(50))
        #expect(GridGeometry.padding == 4)
    }

    // MARK: - ポインタの位置（spec: terminal-mouse「Mouse reporting」）

    @Test func pointerPositionsAccountForPaddingAndScale() {
        let cell = CellMetrics.make(advance: 8.5, ascent: 12, descent: 4, leading: 1, scale: 2) // 8.5 × 17 pt = 17 × 34 px
        let position = GridGeometry.surfacePosition(CGPoint(x: 10.25, y: 20.5), scale: 2)
        #expect(position.x == 20.5)
        #expect(position.y == 41)

        // 余白（4 pt）を引いてからセルにする。
        #expect(GridGeometry.cell(at: CGPoint(x: 4 + 8.5 * 9 + 1, y: 4 + 17 * 4 + 1), cell: cell, cols: 80, rows: 24) == GridPoint(x: 9, y: 4))
        #expect(GridGeometry.cell(at: CGPoint(x: 4 + 8.5 * 9 - 0.5, y: 4 + 17 * 4 - 0.5), cell: cell, cols: 80, rows: 24) == GridPoint(x: 8, y: 3))
        // 余白の中や、グリッドの外はグリッドの端に収める。
        #expect(GridGeometry.cell(at: CGPoint(x: 1, y: 1), cell: cell, cols: 80, rows: 24) == GridPoint(x: 0, y: 0))
        #expect(GridGeometry.cell(at: CGPoint(x: 10_000, y: -50), cell: cell, cols: 80, rows: 24) == GridPoint(x: 79, y: 0))

        // 描画領域（device pixel）。右と下の余白は、セルに収まらない端数を含む。
        let surface = GridGeometry.mouseSurface(viewSize: CGSize(width: 860, height: 520), cell: cell, cols: 100, rows: 30)
        #expect(surface.width == 1720)
        #expect(surface.height == 1040)
        #expect(surface.cellWidth == 17)
        #expect(surface.cellHeight == 34)
        #expect(surface.paddingLeft == 8)
        #expect(surface.paddingTop == 8)
        #expect(surface.paddingRight == 1720 - 8 - 1700)
        #expect(surface.paddingBottom == 1040 - 8 - 1020)
        #expect(surface.columns == 100)
    }

    // ビューの座標から SGR 1006 の報告まで（Retina と標準の画面で、同じセルが報告される）。
    @Test(arguments: [1.0, 2.0])
    func viewPointToSGRReport(scale: CGFloat) throws {
        let cell = CellMetrics.make(advance: 8.5, ascent: 12, descent: 4, leading: 1, scale: scale)
        let terminal = try VTTerminal(cols: 100, rows: 30, maxScrollback: 10)
        try terminal.resize(cols: 100, rows: 30, cellWidthPx: cell.widthPx, cellHeightPx: cell.heightPx)
        terminal.write(Array("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let surface = GridGeometry.mouseSurface(viewSize: CGSize(width: 860, height: 520), cell: cell, cols: 100, rows: 30)
        // 10 列目・5 行目（1 始まり）のセルの中。
        let point = CGPoint(x: GridGeometry.padding + cell.width * 9.5, y: GridGeometry.padding + cell.height * 4.5)
        let position = GridGeometry.surfacePosition(point, scale: scale)
        let press = MouseInput(action: .press, button: .left, x: position.x, y: position.y, anyButtonPressed: true, surface: surface)
        let release = MouseInput(action: .release, button: .left, x: position.x, y: position.y, anyButtonPressed: false, surface: surface)
        #expect(try terminal.encodeMouse(press) == Array("\u{1b}[<0;10;5M".utf8))
        #expect(try terminal.encodeMouse(release) == Array("\u{1b}[<0;10;5m".utf8))
    }
}
