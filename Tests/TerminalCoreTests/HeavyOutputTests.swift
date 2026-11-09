import os
import Testing
@testable import TerminalCore

/// spec: terminal-rendering「Responsiveness under heavy output」、phase5 design D2。
@Suite struct HeavyOutputTests {
    /// 入力のフレームを送った時点で、書き込んでいない出力が何バイト残っていたかを記録する sink。
    final class ProbeSink: TerminalFrameSink, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (controller: TerminalController?.none, pending: [Int](), inputs: [[UInt8]]()))

        var controller: TerminalController? {
            get { state.withLock { $0.controller } }
            set { state.withLock { $0.controller = newValue } }
        }

        var pendingAtInput: [Int] { state.withLock { $0.pending } }
        var inputs: [[UInt8]] { state.withLock { $0.inputs } }

        func enqueue(_ frame: TerminalOutgoingFrame) -> Bool {
            if case .input(_, let bytes) = frame {
                state.withLock { state in
                    state.pending.append(state.controller?.pendingOutputBytes ?? -1)
                    state.inputs.append(bytes)
                }
            }
            return true
        }
    }

    private static func bigOutput(megabytes: Int) -> [UInt8] {
        let line = Array("drwxr-xr-x  12 user  staff   384 Nov  9 10:52 some-directory-name-here.txt\r\n".utf8)
        var big: [UInt8] = []
        big.reserveCapacity(megabytes << 20 + line.count)
        while big.count < megabytes << 20 { big += line }
        return big
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    // 大きな書き込みの途中で送った入力は、書き込みが終わるのを待たずに送られる。
    @Test func inputIsSentWhileALargeWriteIsInProgress() async throws {
        let sink = ProbeSink()
        let controller = try TerminalController(sid: "s1", cols: 160, rows: 50, maxScrollback: 1000, colors: nil, sink: sink)
        sink.controller = controller
        await controller.attach()
        await controller.receiveReplay([], done: true)

        let big = Self.bigOutput(megabytes: 48)
        controller.enqueueOutput(big)
        // 書き始めたら（残りが減ったら）キーを送る。
        #expect(await waitUntil { controller.pendingOutputBytes < big.count })
        controller.enqueueText("x")
        #expect(await waitUntil { !sink.inputs.isEmpty })
        #expect(sink.inputs.first == Array("x".utf8))
        let pending = try #require(sink.pendingAtInput.first)
        #expect(pending > 0, "入力を送ったときに、出力は書き終わっていた")

        await controller.waitUntilIncomingIsWritten()
        #expect(controller.pendingOutputBytes == 0)
    }

    // デーモンのフレーム（32 KiB ほど）がたくさん積まれていても、フレームの間で入力を送る。
    @Test func inputIsSentBetweenManySmallFrames() async throws {
        let sink = ProbeSink()
        let controller = try TerminalController(sid: "s1", cols: 160, rows: 50, maxScrollback: 1000, colors: nil, sink: sink)
        sink.controller = controller
        await controller.attach()
        await controller.receiveReplay([], done: true)
        let big = Self.bigOutput(megabytes: 48)
        var offset = 0
        while offset < big.count {
            let end = min(offset + 32 * 1024, big.count)
            controller.enqueueOutput(Array(big[offset..<end]))
            offset = end
        }
        #expect(await waitUntil { controller.pendingOutputBytes < big.count })
        controller.enqueueText("y")
        #expect(await waitUntil { !sink.inputs.isEmpty })
        let pending = try #require(sink.pendingAtInput.first)
        #expect(pending > 0, "入力を送ったときに、出力は書き終わっていた")
        await controller.waitUntilIncomingIsWritten()
    }

    // 64 KiB ずつに分けて書いても、一度に書いたときと同じ画面になる（シーケンスや UTF-8 の途中で区切ってよい）。
    @Test func chunkedWritesProduceTheSameScreen() async throws {
        var stream: [UInt8] = []
        for index in 0..<12000 {
            stream += Array("\u{1b}[3\(index % 8)m行 \(index) – ünïcödé 😀\u{1b}[0m\r\n".utf8)
        }
        #expect(stream.count > TerminalController.writeChunkSize * 3)

        let reference = try VTTerminal(cols: 80, rows: 24, maxScrollback: 100)
        reference.write(stream)

        let controller = try TerminalController(sid: "s1", cols: 80, rows: 24, maxScrollback: 100, colors: nil, sink: ProbeSink())
        await controller.attach()
        await controller.receiveReplay([], done: true)
        controller.enqueueOutput(Array(stream.prefix(100_001)))
        controller.enqueueOutput(Array(stream.dropFirst(100_001)))
        await controller.waitUntilIncomingIsWritten()
        #expect(await controller.plainText() == (try reference.plainText()))
    }

    // attach し直したら、積んであった出力と、書き込み途中の出力の残りは捨てる（replay で最初から受け取る）。
    @Test func reattachDiscardsQueuedOutput() async throws {
        let controller = try TerminalController(sid: "s1", cols: 80, rows: 24, maxScrollback: 100, colors: nil, sink: ProbeSink())
        await controller.attach()
        await controller.receiveReplay([], done: true)
        controller.enqueueOutput(Self.bigOutput(megabytes: 32))
        controller.enqueueOutput(Array("stale".utf8))
        #expect(await waitUntil { controller.pendingOutputBytes < 32 << 20 })
        await controller.attach()
        #expect(controller.pendingOutputBytes == 0)
        controller.enqueueReplay(Array("fresh".utf8), done: true)
        await controller.waitUntilIncomingIsWritten()
        #expect(await controller.plainText() == "fresh")
        #expect(await controller.phase == .live)
    }

    // replay と output は、積んだ順に書く。replay 中の output は捨てる（今までと同じ）。
    @Test func queuedFramesKeepTheirOrder() async throws {
        let sink = ProbeSink()
        let controller = try TerminalController(sid: "s1", cols: 80, rows: 24, maxScrollback: 100, colors: nil, sink: sink)
        await controller.attach()
        controller.enqueueOutput(Array("dropped ".utf8))
        controller.enqueueReplay(Array("a".utf8), done: false)
        controller.enqueueReplay(Array("b".utf8), done: true)
        controller.enqueueOutput(Array("c".utf8))
        await controller.waitUntilIncomingIsWritten()
        #expect(await controller.plainText() == "abc")
    }
}
