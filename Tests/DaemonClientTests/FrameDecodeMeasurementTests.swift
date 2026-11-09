import Foundation
import Testing
@testable import DaemonClient

/// docs/performance.md の計測: 受信したフレームのデコード（JSON + base64）の速さ。
/// `TABGHOSTTY_BENCH=1` のときだけ実行する（`PerformanceMeasurementTests` と同じ）。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TABGHOSTTY_BENCH"] == "1"))
struct FrameDecodeMeasurementTests {
    @Test func outputFrameDecodeThroughput() throws {
        let line = Array("drwxr-xr-x  12 user  staff   384 Nov  9 10:52 some-directory-name-here.txt\r\n".utf8)
        var chunk: [UInt8] = []
        while chunk.count < 32 * 1024 { chunk += line }
        chunk = Array(chunk.prefix(32 * 1024))
        let frame = Data(#"{"t":"output","sid":"s1","data":"\#(Data(chunk).base64EncodedString())"}"#.utf8)
        let clock = ContinuousClock()
        let start = clock.now
        var total = 0
        for _ in 0..<1024 {
            if case .output(_, let data)? = ServerFrame.decode(frame) { total += data.count }
        }
        let elapsed = clock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print(String(format: "BENCH decode %d output frames of 32 KiB (%.1f MB) in %.1f ms (%.0f MB/s)",
                     1024, Double(total) / 1_048_576, milliseconds, Double(total) / 1_048_576 / (milliseconds / 1000)))
        #expect(total == 32 << 20)
    }
}
