import Foundation
import os
import Testing
@testable import TerminalCore

/// コントローラが預かった observer を、何度呼んでも包み直さない。
///
/// クロージャをそのまま `OSAllocatedUnfairLock` に入れていたときは、`withLock { $0 }` で読むたびに
/// reabstraction thunk で包み直したクロージャが書き戻され、呼ぶときのスタックが読んだ回数だけ深くなっていた。
/// 出力が数千回届くと、協調スレッドのスタック（512 KiB）が溢れてクラッシュした。
@Suite struct ObserverStorageTests {
    private static let reads = 300

    private func liveController() async throws -> TerminalController {
        let controller = try TerminalController(sid: "s1", cols: 20, rows: 4, maxScrollback: 10, colors: nil, sink: RecordingSink())
        await controller.attach()
        await controller.receiveReplay(bytes("old"), done: true)
        _ = await controller.makeSnapshot(forceFull: true)
        return controller
    }

    @Test func renderObserverStackDepthDoesNotGrow() async throws {
        let controller = try await liveController()
        let depths = OSAllocatedUnfairLock(initialState: [Int]())
        controller.setRenderObserver { depths.withLock { $0.append(Thread.callStackSymbols.count) } }
        for _ in 0..<Self.reads {
            await controller.receiveOutput(bytes("x"))
            // 描画すべき変化を取り込んで、次の出力でまた知らせるようにする。
            _ = await controller.makeSnapshot()
        }
        let recorded = depths.withLock { $0 }
        #expect(recorded.count >= Self.reads)
        let first = try #require(recorded.first)
        let last = try #require(recorded.last)
        #expect(last - first < 20, "observer の呼び出しが \(first) → \(last) フレームに深くなった")
    }

    @Test func searchObserverStackDepthDoesNotGrow() async throws {
        let controller = try await liveController()
        await controller.search("old")
        let depths = OSAllocatedUnfairLock(initialState: [Int]())
        controller.setSearchObserver { _ in depths.withLock { $0.append(Thread.callStackSymbols.count) } }
        for _ in 0..<Self.reads {
            // 検索中に attach し直すと、一致が無くなったことを知らせる。
            await controller.attach()
        }
        let recorded = depths.withLock { $0 }
        #expect(recorded.count == Self.reads)
        let first = try #require(recorded.first)
        let last = try #require(recorded.last)
        #expect(last - first < 20, "observer の呼び出しが \(first) → \(last) フレームに深くなった")
    }
}
