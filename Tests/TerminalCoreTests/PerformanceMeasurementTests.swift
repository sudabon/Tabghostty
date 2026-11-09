import Darwin
import Foundation
import os
import Testing
@testable import TerminalCore

/// docs/performance.md の計測のうち、アプリを起動せずに測れるもの（phase5 design D8）。
///
/// 時間がかかるので、ふだんの `make test` では実行しない。`TABGHOSTTY_BENCH=1 swift test --filter PerformanceMeasurementTests`
/// で実行し、結果は標準出力に `BENCH` で始まる行として出す。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TABGHOSTTY_BENCH"] == "1"), .serialized)
struct PerformanceMeasurementTests {
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func megabytes(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func lines(count: Int, width: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count * (width + 2))
        for index in 0..<count {
            let prefix = Array("\(index) ".utf8)
            bytes += prefix
            bytes += [UInt8](repeating: UInt8(ascii: "a") + UInt8(index % 26), count: max(0, width - prefix.count))
            bytes += [13, 10]
        }
        return bytes
    }

    // 30 タブ × scrollback 10000 行（120 列）のメモリ。
    @Test func memoryForThirtyTabsWithFullScrollback() async throws {
        let before = Self.footprint()
        var controllers: [TerminalController] = []
        let text = Self.lines(count: 10_100, width: 120)
        for index in 0..<30 {
            let controller = try TerminalController(sid: "s\(index)", cols: 120, rows: 40, maxScrollback: 10_000, colors: nil, sink: RecordingSink())
            await controller.attach()
            await controller.receiveReplay(text, done: true)
            _ = await controller.makeSnapshot(forceFull: true)
            controllers.append(controller)
        }
        let after = Self.footprint()
        var resident: UInt64 = 0
        var rows = 0
        for controller in controllers {
            resident += await controller.withTerminal { $0.memoryUsage.residentBytes }
            rows += await controller.withTerminal { $0.scrollbackRows }
        }
        print("BENCH memory 30 terminals x 10000 lines (120 cols): libghostty resident \(Self.megabytes(resident)), process footprint +\(Self.megabytes(after - before)) (before \(Self.megabytes(before)), after \(Self.megabytes(after))), scrollback rows \(rows)")
        // libghostty はページ単位で古い行を消すので、上限より少し少ないことがある。
        #expect(rows > 30 * 9_000)
    }

    // 書き込みとフレームのデコードの速さ。
    @Test func writeThroughput() throws {
        let data = Self.lines(count: 400_000, width: 80)
        let terminal = try VTTerminal(cols: 160, rows: 50, maxScrollback: 10_000)
        let clock = ContinuousClock()
        let start = clock.now
        var offset = 0
        while offset < data.count {
            let end = min(offset + TerminalController.writeChunkSize, data.count)
            terminal.write(data[offset..<end])
            offset = end
        }
        let elapsed = clock.now - start
        let mb = Double(data.count) / 1_048_576
        print(String(format: "BENCH vt write %.1f MB in %.1f ms (%.0f MB/s, 64 KiB chunks)", mb, Self.milliseconds(elapsed), mb / (Self.milliseconds(elapsed) / 1000)))
    }

    // 50 MB の出力を書き込んでいる端末がある間に、ほかの端末（とその端末自身）に入力を送ったときの、
    // `enqueueText` から input フレームを送るまでの時間（アプリの中の入力の経路だけ。デーモンとの往復は含まない）。
    @Test func inputLatencyWhileWriting50MB() async throws {
        final class TimingSink: TerminalFrameSink, @unchecked Sendable {
            let sent = OSAllocatedUnfairLock(initialState: [ContinuousClock.Instant]())
            func enqueue(_ frame: TerminalOutgoingFrame) -> Bool {
                if case .input = frame { sent.withLock { $0.append(.now) } }
                return true
            }
        }
        let busySink = TimingSink()
        let busy = try TerminalController(sid: "busy", cols: 160, rows: 50, maxScrollback: 10_000, colors: nil, sink: busySink)
        await busy.attach()
        await busy.receiveReplay([], done: true)
        let data = Self.lines(count: 660_000, width: 78)
        #expect(data.count >= 50 << 20)

        let start = ContinuousClock.now
        // デーモンは 32 KiB ほどのフレームで送るので、同じ大きさで積む。
        var offset = 0
        while offset < data.count {
            let end = min(offset + 32 * 1024, data.count)
            busy.enqueueOutput(Array(data[offset..<end]))
            offset = end
        }
        var latencies: [Double] = []
        while busy.pendingOutputBytes > 0 {
            let before = busySink.sent.withLock { $0.count }
            let pressed = ContinuousClock.now
            busy.enqueueText("x")
            while busySink.sent.withLock({ $0.count }) == before {
                try await Task.sleep(for: .microseconds(200))
            }
            latencies.append(Self.milliseconds(busySink.sent.withLock { $0.last! } - pressed))
        }
        await busy.waitUntilIncomingIsWritten()
        let total = ContinuousClock.now - start
        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)] }
        print(String(
            format: "BENCH input while writing 50 MB to the same terminal: n=%d p50=%.2f ms p95=%.2f ms max=%.2f ms (write took %.0f ms)",
            sorted.count, percentile(0.5), percentile(0.95), sorted.last ?? 0, Self.milliseconds(total)
        ))
        #expect(percentile(0.95) < 100)
    }
}
