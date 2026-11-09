import Foundation
import os

/// 入力遅延の計測（phase5 tasks 3.2、design D8）。環境変数 `TABGHOSTTY_LATENCY_LOG=1` のときだけ動く。
///
/// キーを押してから（`keyDown`）、そのあとに受け取った端末の変化（エコー）を画面に出すまでの時間を測り、
/// 1 回ごとと、`reportInterval` 回ごとの集計（中央値・95 パーセンタイル・最大）をログに出す。
///
///     TABGHOSTTY_LATENCY_LOG=1 build/Tabghostty.app/Contents/MacOS/Tabghostty
///     log stream --predicate 'subsystem == "Tabghostty" && category == "latency"'
///
/// 標準エラーにも同じ行を出す（ターミナルから起動したときに見えるように）。
@MainActor
final class InputLatencyProbe {
    static let environmentKey = "TABGHOSTTY_LATENCY_LOG"
    /// この回数ごとに集計を出す。
    static let reportInterval = 50

    private static let logger = Logger(subsystem: "Tabghostty", category: "latency")

    /// 環境変数で有効にしたときだけ作る。
    static func makeIfEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> InputLatencyProbe? {
        guard let value = environment[environmentKey], ["1", "true", "yes"].contains(value.lowercased()) else { return nil }
        return InputLatencyProbe()
    }

    private let clock = ContinuousClock()
    /// まだ画面に出ていないキーを押した時刻。
    private var pendingKeys: [ContinuousClock.Instant] = []
    /// キーを押したあとに、端末の変化を受け取った。
    private var receivedChange = false
    private(set) var samples: [Double] = []
    /// 出力先（テストで差し替える）。
    var emit: (String) -> Void = { line in
        InputLatencyProbe.logger.notice("\(line, privacy: .public)")
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// キーを押した。
    func keyDown() {
        pendingKeys.append(clock.now)
        receivedChange = false
    }

    /// 端末の変化（スナップショットの行やカーソルの変化）を受け取った。
    func snapshotChanged() {
        guard !pendingKeys.isEmpty else { return }
        receivedChange = true
    }

    /// フレームを画面に出した。キーのあとに受け取った変化が含まれていれば、遅延として記録する。
    func framePresented() {
        guard receivedChange, !pendingKeys.isEmpty else { return }
        let now = clock.now
        for key in pendingKeys {
            let elapsed = now - key
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            samples.append(milliseconds)
            emit(String(format: "input-latency ms=%.1f", milliseconds))
        }
        pendingKeys.removeAll()
        receivedChange = false
        if samples.count % Self.reportInterval == 0 {
            emit(summary)
        }
    }

    /// 集計（中央値・95 パーセンタイル・最大）。
    var summary: String {
        guard !samples.isEmpty else { return "input-latency summary n=0" }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count) * p).rounded(.up)) - 1)]
        }
        return String(
            format: "input-latency summary n=%d p50=%.1f p95=%.1f max=%.1f",
            sorted.count, percentile(0.5), percentile(0.95), sorted.last!
        )
    }
}
