import Testing
@testable import TerminalUI

/// phase5 tasks 3.2: 入力遅延の計測。
@MainActor
@Suite struct InputLatencyProbeTests {
    @Test func enabledOnlyByTheEnvironment() {
        #expect(InputLatencyProbe.makeIfEnabled([:]) == nil)
        #expect(InputLatencyProbe.makeIfEnabled(["TABGHOSTTY_LATENCY_LOG": "0"]) == nil)
        #expect(InputLatencyProbe.makeIfEnabled(["TABGHOSTTY_LATENCY_LOG": "1"]) != nil)
    }

    @Test func measuresFromKeyDownToTheFrameShowingTheEcho() async throws {
        let probe = try #require(InputLatencyProbe.makeIfEnabled(["TABGHOSTTY_LATENCY_LOG": "1"]))
        var lines: [String] = []
        probe.emit = { lines.append($0) }
        // 変化を受け取る前のフレーム（点滅など）は数えない。
        probe.keyDown()
        probe.framePresented()
        #expect(probe.samples.isEmpty)
        try await Task.sleep(for: .milliseconds(20))
        probe.snapshotChanged()
        probe.framePresented()
        #expect(probe.samples.count == 1)
        #expect(probe.samples[0] >= 20)
        #expect(lines.first?.hasPrefix("input-latency ms=") == true)
        // キーを押していないときの変化は数えない。
        probe.snapshotChanged()
        probe.framePresented()
        #expect(probe.samples.count == 1)
        #expect(probe.summary.hasPrefix("input-latency summary n=1 p50="))
    }
}
