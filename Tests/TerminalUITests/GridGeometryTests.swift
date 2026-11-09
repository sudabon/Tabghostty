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
}
