import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// 全角文字（2 セル幅）の強調: 検索の一致や選択が全角文字で終わるとき、その文字の右半分のセル（spacer tail）も塗る。
/// libghostty は、一致や選択の終わりの列として全角文字の左半分の列を返す。
@MainActor
@Suite struct WideCellHighlightTests {
    private let palette = Palette.dark

    private func makeController(_ text: String) async throws -> TerminalController {
        let controller = try TerminalController(sid: "s1", cols: 40, rows: 4, maxScrollback: 10, colors: palette.terminalColors, sink: RecordingSink())
        await controller.attach()
        await controller.receiveReplay(Array(text.utf8), done: true)
        return controller
    }

    private func show(_ controller: TerminalController) async throws -> (view: TerminalView, row: [CellSnapshot]) {
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: palette, renderer: .coreText)
        view.controller = controller
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let snapshot = try #require(await controller.makeSnapshot(forceFull: true))
        view.apply(snapshot)
        let row = try #require(snapshot.dirtyRows.first { $0.y == 0 }?.cells)
        return (view, row)
    }

    // "ab日本語cd": 日 は列 2–3、本 は列 4–5、語 は列 6–7。
    @Test func searchMatchEndingInAWideCharacterCoversItsRightHalf() async throws {
        let controller = try await makeController("ab日本語cd")
        #expect(await controller.search("日本").total == 1)
        let (view, row) = try await show(controller)
        #expect(row[5].width == .spacerTail)
        for x in 2...5 {
            #expect(view.rowCellColors(row[x], x: x, y: 0).background == palette.searchCurrentMatch, "column \(x)")
        }
        #expect(view.rowCellColors(row[6], x: 6, y: 0).background != palette.searchCurrentMatch)
        #expect(view.rowCellColors(row[1], x: 1, y: 0).background != palette.searchCurrentMatch)
    }

    // 列 0 から、日（列 2–3）が選択に入る位置（左半分の右側から右半分まで）までドラッグすると、日 の両半分が選択の色になる。
    // （左半分の左側で終えると、日 は選択に入らない。）
    @Test(arguments: [(2, true), (3, false), (3, true)])
    func selectionEndingInAWideCharacterCoversItsRightHalf(endColumn: Int, rightEdge: Bool) async throws {
        let controller = try await makeController("ab日本語cd")
        let surface = MouseSurface(
            width: 800, height: 200, cellWidth: 16, cellHeight: 34, paddingTop: 8, paddingBottom: 8,
            paddingLeft: 8, paddingRight: 8, columns: 40
        )
        func input(_ kind: SelectionInput.Kind, _ column: Int, edge: Bool) -> SelectionInput {
            SelectionInput(kind: kind, cell: GridPoint(x: column, y: 0), x: Double(8 + column * 16 + (edge ? 15 : 2)), y: 25, surface: surface)
        }
        controller.enqueueSelection(input(.press(timeNanoseconds: 1, repeatIntervalNanoseconds: 1, repeatDistance: 1), 0, edge: false))
        controller.enqueueSelection(input(.drag, endColumn, edge: rightEdge))
        controller.enqueueSelection(input(.release, endColumn, edge: rightEdge))
        await controller.flushInput()

        let (view, row) = try await show(controller)
        #expect(row[3].width == .spacerTail)
        for x in 0...3 {
            #expect(view.rowCellColors(row[x], x: x, y: 0).background == palette.selection, "column \(x), end \(endColumn) \(rightEdge)")
        }
        #expect(view.rowCellColors(row[4], x: 4, y: 0).background != palette.selection)
    }
}
