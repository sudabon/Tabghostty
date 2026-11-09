import Testing
@testable import TerminalCore

/// spec: terminal-engine「Serialized access per terminal」。
/// Thread Sanitizer 付き（`make test-tsan` / `swift test --sanitize=thread`）でも実行する。
@Suite struct TerminalControllerConcurrencyTests {
    // Scenario: Concurrent producers
    @Test func concurrentWritesAndResizesDoNotRace() async throws {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", maxScrollback: 1000, colors: nil, sink: sink)
        await controller.attach()
        await controller.receiveReplay([], done: true)
        #expect(await controller.phase == .live)

        let writes = 400
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<writes {
                group.addTask {
                    await controller.receiveOutput(bytes("a"))
                }
                if index.isMultiple(of: 4) {
                    group.addTask {
                        let wide = index.isMultiple(of: 8)
                        await controller.setViewGrid(.init(
                            cols: wide ? 100 : 80, rows: wide ? 30 : 24, cellWidthPx: 16, cellHeightPx: 34
                        ))
                    }
                }
                if index.isMultiple(of: 16) {
                    group.addTask {
                        _ = await controller.makeSnapshot()
                    }
                }
            }
        }

        // 折り返しの位置はリサイズで変わるが、書いた文字はすべて画面に残っている。
        let text = await controller.plainText()
        #expect(text.filter { $0 == "a" }.count == writes)
    }

    // 別々の端末は独立して使える。
    @Test func differentTerminalsAreIndependent() async throws {
        let sink = RecordingSink()
        let first = try TerminalController(sid: "a", maxScrollback: 100, colors: nil, sink: sink)
        let second = try TerminalController(sid: "b", maxScrollback: 100, colors: nil, sink: sink)
        for controller in [first, second] {
            await controller.attach()
            await controller.receiveReplay([], done: true)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { await first.receiveOutput(bytes("1")) }
                group.addTask { await second.receiveOutput(bytes("2")) }
            }
        }
        #expect(await first.plainText() == String(repeating: "1", count: 80) + "\n" + String(repeating: "1", count: 20))
        #expect(await second.plainText() == String(repeating: "2", count: 80) + "\n" + String(repeating: "2", count: 20))
    }
}
