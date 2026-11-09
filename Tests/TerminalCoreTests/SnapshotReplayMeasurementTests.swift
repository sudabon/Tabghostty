import Foundation
import GhosttyVt
import Testing
@testable import TerminalCore

/// docs/adr/0001-snapshot-replay.md の計測（phase6 design D6）。Terminal Snapshot の大きさ、エンコード・デコードの時間、
/// 端末を保持するメモリを、今の replay（リングバッファのバイト列をそのまま流す）と比べる。
///
/// 時間がかかるので、ふだんの `make test` では実行しない。
/// `TABGHOSTTY_BENCH=1 swift test --filter SnapshotReplayMeasurementTests` で実行し、結果は `BENCH` で始まる行に出す。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TABGHOSTTY_BENCH"] == "1"), .serialized)
struct SnapshotReplayMeasurementTests {
    /// デーモンのリングバッファの大きさ（webtabinal `internal/session` の 5 MiB）。
    static let ringBufferBytes = 5 * 1024 * 1024

    // MARK: - 計測の部品

    /// 端末の Snapshot をエンコードする。
    static func encode(_ handle: GhosttyTerminal) throws -> [UInt8] {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try VTTerminal.check(ghostty_snapshot_encode_alloc(handle, nil, &pointer, &length), "ghostty_snapshot_encode_alloc")
        defer { ghostty_free(nil, pointer, length) }
        guard let pointer else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: length))
    }

    /// Snapshot から端末を復元する（一度に最後まで）。返した端末は `ghostty_terminal_free` で解放する。
    static func decode(_ snapshot: [UInt8], compressHistory: Bool = false) throws -> GhosttyTerminal {
        try snapshot.withUnsafeBufferPointer { buffer in
            var decoder: GhosttySnapshotDecoder?
            try VTTerminal.check(
                ghostty_snapshot_decoder_new_buf(nil, &decoder, buffer.baseAddress, buffer.count),
                "ghostty_snapshot_decoder_new_buf"
            )
            guard let decoder else { throw VTError(function: "ghostty_snapshot_decoder_new_buf", code: GHOSTTY_INVALID_VALUE.rawValue) }
            defer { ghostty_snapshot_decoder_free(decoder) }
            var compress = compressHistory
            try VTTerminal.check(
                ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &compress),
                "ghostty_snapshot_decoder_set(COMPRESS_HISTORY)"
            )
            var terminal: GhosttyTerminal?
            try VTTerminal.check(ghostty_snapshot_decoder_decode(decoder, &terminal), "ghostty_snapshot_decoder_decode")
            guard let terminal else { throw VTError(function: "ghostty_snapshot_decoder_decode", code: GHOSTTY_INVALID_VALUE.rawValue) }
            return terminal
        }
    }

    /// フォーマッタの出力（画面全体。VT なら `extras` の状態も含める）。
    static func format(_ handle: GhosttyTerminal, emit: GhosttyFormatterFormat, extras: GhosttyFormatterExtras? = nil) throws -> [UInt8] {
        var formatter: GhosttyFormatter?
        try VTTerminal.check(ghostty_formatter_terminal_new(nil, &formatter, handle), "ghostty_formatter_terminal_new")
        guard let formatter else { throw VTError(function: "ghostty_formatter_terminal_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        defer { ghostty_formatter_free(formatter) }
        var emit = emit
        try VTTerminal.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit), "ghostty_formatter_set(EMIT)")
        if var extras {
            try VTTerminal.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras), "ghostty_formatter_set(EXTRAS)")
        }
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try VTTerminal.check(ghostty_formatter_format_alloc(formatter, nil, &pointer, &length), "ghostty_formatter_format_alloc")
        defer { ghostty_free(nil, pointer, length) }
        guard let pointer else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: length))
    }

    /// libghostty が端末のために使っているメモリ（両方の画面の合計）。
    static func resident(_ handle: GhosttyTerminal) -> UInt64 {
        var usage = GhosttyTerminalMemoryUsage()
        ghostty_sized_init(&usage, MemoryLayout<GhosttyTerminalMemoryUsage>.size)
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &usage) == GHOSTTY_SUCCESS else { return 0 }
        return usage.primary_resident_bytes + usage.alternate_resident_bytes
    }

    static func setContinuationLimit(_ handle: GhosttyTerminal, _ bytes: Int) throws {
        var limit = UInt(bytes)
        try VTTerminal.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &limit),
            "ghostty_terminal_set(CONTINUATION_MAX_BYTES)"
        )
    }

    /// `runs` 回実行して、かかった時間の中央値（ミリ秒）を返す。
    static func medianMilliseconds(runs: Int, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = clock.now
            try body()
            let elapsed = clock.now - start
            samples.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        return samples.sorted()[samples.count / 2]
    }

    static func megabytes(_ bytes: some BinaryInteger) -> String { String(format: "%.2f MB", Double(bytes) / 1_048_576) }
    static func kilobytes(_ bytes: some BinaryInteger) -> String { String(format: "%.1f KB", Double(bytes) / 1024) }

    /// JSON の replay フレームでの大きさ（base64 にしたデータ部分だけ。24 KiB ずつのフレームの枠は数えない）。
    static func base64Size(_ bytes: Int) -> Int { (bytes + 2) / 3 * 4 }

    // MARK: - 出力の作り方

    /// コーディングエージェントの TUI に近い出力（SGR の色、日本語、折り返す長い行、スピナーの書き換え）を `size` バイト作る。
    static func agentLikeOutput(size: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size + 4096)
        var step = 0
        while bytes.count < size {
            step += 1
            // スピナー: 同じ行を何度も書き換える（今の replay では、書き換えたバイトもすべて送る）。
            for tick in 0..<8 {
                bytes += Array("\u{1b}[?25l\r\u{1b}[2K\u{1b}[33m✻\u{1b}[0m Thinking… (\(step)s · \(tick)) \u{1b}[2mesc to interrupt\u{1b}[0m".utf8)
            }
            bytes += Array("\r\u{1b}[2K\u{1b}[?25h".utf8)
            bytes += Array("\u{1b}[32m⏺\u{1b}[0m \u{1b}[1mRead\u{1b}[0m(Sources/TerminalCore/ScreenNormalizer.swift) — \(step) 行目を読みました\r\n".utf8)
            bytes += Array("  \u{1b}[38;5;245m⎿  Found \(step % 7) files in 日本語のディレクトリ\u{1b}[0m\r\n".utf8)
            for line in 0..<6 {
                bytes += Array("\u{1b}[2m\(String(format: "%4d", line + 1)) │\u{1b}[0m let value\(line) = compute(\"日本語のテキスト \(step)\", count: \(line * step))\r\n".utf8)
            }
            let long = String(repeating: "wrap-\(step % 10) ", count: 30)
            bytes += Array("\u{1b}[36m\(long)\u{1b}[0m\r\n".utf8)
        }
        return bytes
    }

    /// 1 行 `width` 文字の ASCII の行（ビルドのログや `seq` のような出力）を `size` バイト作る。
    static func plainLines(size: Int, width: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size + width + 2)
        var index = 0
        while bytes.count < size {
            let prefix = Array("\(index) ".utf8)
            bytes += prefix
            bytes += [UInt8](repeating: UInt8(ascii: "a") + UInt8(index % 26), count: max(0, width - prefix.count))
            bytes += [13, 10]
            index += 1
        }
        return bytes
    }

    // MARK: - 計測

    struct Scenario {
        var name: String
        var cols: Int
        var rows: Int
        var maxScrollback: Int
        var stream: [UInt8]
    }

    private func measure(_ scenario: Scenario) throws {
        let source = try VTTerminal(cols: scenario.cols, rows: scenario.rows, maxScrollback: scenario.maxScrollback)
        try Self.setContinuationLimit(source.handle, 4096)

        // 今の replay のクライアント側の費用: リングバッファのバイト列を新しい端末に書き込む。
        let replayWrite = try Self.medianMilliseconds(runs: 3) {
            let terminal = try VTTerminal(cols: scenario.cols, rows: scenario.rows, maxScrollback: scenario.maxScrollback)
            var offset = 0
            while offset < scenario.stream.count {
                let end = min(offset + TerminalController.writeChunkSize, scenario.stream.count)
                terminal.write(scenario.stream[offset..<end])
                offset = end
            }
        }
        var offset = 0
        while offset < scenario.stream.count {
            let end = min(offset + TerminalController.writeChunkSize, scenario.stream.count)
            source.write(scenario.stream[offset..<end])
            offset = end
        }

        var snapshot: [UInt8] = []
        let encode = try Self.medianMilliseconds(runs: 5) { snapshot = try Self.encode(source.handle) }
        let decode = try Self.medianMilliseconds(runs: 3) { ghostty_terminal_free(try Self.decode(snapshot)) }
        let decodeCompressed = try Self.medianMilliseconds(runs: 3) { ghostty_terminal_free(try Self.decode(snapshot, compressHistory: true)) }

        let restored = try Self.decode(snapshot)
        defer { ghostty_terminal_free(restored) }
        let restoredCompressed = try Self.decode(snapshot, compressHistory: true)
        defer { ghostty_terminal_free(restoredCompressed) }
        // 復元した端末は、画面もスクロールバックも元と同じ（VT のフォーマッタの出力で比べる）。
        let allExtras: GhosttyFormatterExtras = 0xFFF // GHOSTTY_FORMATTER_EXTRAS_ALL
        let originalVT = try Self.format(source.handle, emit: GHOSTTY_FORMATTER_FORMAT_VT, extras: allExtras)
        #expect(try Self.format(restored, emit: GHOSTTY_FORMATTER_FORMAT_VT, extras: allExtras) == originalVT)

        // ブラウザ版でも使える別案: 画面とスクロールバックを VT のシーケンスとして作り直して送る。
        var vt: [UInt8] = []
        let vtFormat = try Self.medianMilliseconds(runs: 3) { vt = try Self.format(source.handle, emit: GHOSTTY_FORMATTER_FORMAT_VT) }

        let residentBefore = Self.resident(source.handle)
        var compression = GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED
        _ = ghostty_terminal_compress(source.handle, GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL, &compression)
        let residentCompressed = Self.resident(source.handle)

        print("BENCH snapshot [\(scenario.name)] \(scenario.cols)x\(scenario.rows) scrollback \(scenario.maxScrollback) (kept \(source.scrollbackRows) rows)")
        print("BENCH snapshot [\(scenario.name)]   replay today: stream \(Self.megabytes(scenario.stream.count)), JSON base64 \(Self.megabytes(Self.base64Size(scenario.stream.count))), client write \(String(format: "%.1f", replayWrite)) ms")
        print("BENCH snapshot [\(scenario.name)]   snapshot: \(Self.megabytes(snapshot.count)) (\(String(format: "%.1f", Double(snapshot.count) / Double(scenario.stream.count) * 100))% of stream), encode \(String(format: "%.1f", encode)) ms, decode \(String(format: "%.1f", decode)) ms, decode+compress \(String(format: "%.1f", decodeCompressed)) ms")
        print("BENCH snapshot [\(scenario.name)]   VT re-render (browser-compatible alternative): \(Self.megabytes(vt.count)), format \(String(format: "%.1f", vtFormat)) ms")
        print("BENCH snapshot [\(scenario.name)]   terminal memory (daemon would hold): resident \(Self.megabytes(residentBefore)), after full compress \(Self.megabytes(residentCompressed)) (\(compression)); restored \(Self.megabytes(Self.resident(restored))), restored with compress-history \(Self.megabytes(Self.resident(restoredCompressed)))")
    }

    @Test func agentLikeOutputWithFullScrollback() throws {
        try measure(Scenario(name: "agent-like 5 MiB", cols: 120, rows: 40, maxScrollback: 10_000, stream: Self.agentLikeOutput(size: Self.ringBufferBytes)))
    }

    @Test func agentLikeOutputWithShortScrollback() throws {
        try measure(Scenario(name: "agent-like 5 MiB, scrollback 1000", cols: 120, rows: 40, maxScrollback: 1_000, stream: Self.agentLikeOutput(size: Self.ringBufferBytes)))
    }

    @Test func plainLinesWithFullScrollback() throws {
        try measure(Scenario(name: "plain lines 5 MiB", cols: 120, rows: 40, maxScrollback: 10_000, stream: Self.plainLines(size: Self.ringBufferBytes, width: 80)))
    }

    @Test func smallSessionAfterAttach() throws {
        // 起動して少しだけ使ったセッション（フィクスチャ程度の出力）。
        try measure(Scenario(name: "agent-like 64 KiB", cols: 120, rows: 40, maxScrollback: 10_000, stream: Self.agentLikeOutput(size: 64 * 1024)))
    }

    @Test func fixtures() throws {
        var streamTotal = 0
        var snapshotTotal = 0
        var snapshotMax = 0
        var encodeTotal = 0.0
        for fixture in FixtureStreamTests.fixtures {
            let terminal = try VTTerminal(cols: fixture.columns, rows: fixture.rows, maxScrollback: 10_000)
            try Self.setContinuationLimit(terminal.handle, 4096)
            terminal.write(fixture.stream)
            var snapshot: [UInt8] = []
            encodeTotal += try Self.medianMilliseconds(runs: 5) { snapshot = try Self.encode(terminal.handle) }
            let restored = try Self.decode(snapshot)
            defer { ghostty_terminal_free(restored) }
            #expect(
                try Self.format(restored, emit: GHOSTTY_FORMATTER_FORMAT_VT, extras: 0xFFF)
                    == Self.format(terminal.handle, emit: GHOSTTY_FORMATTER_FORMAT_VT, extras: 0xFFF),
                "\(fixture.name)"
            )
            streamTotal += fixture.stream.count
            snapshotTotal += snapshot.count
            snapshotMax = max(snapshotMax, snapshot.count)
        }
        let count = FixtureStreamTests.fixtures.count
        print("BENCH snapshot [fixtures x\(count)] stream total \(Self.kilobytes(streamTotal)), snapshot total \(Self.kilobytes(snapshotTotal)) (max \(Self.kilobytes(snapshotMax))), encode avg \(String(format: "%.3f", encodeTotal / Double(count))) ms")
    }

    // 今の replay は、リングバッファの先頭がシーケンスや UTF-8 の途中から始まることがある。Snapshot は
    // 書きかけのシーケンス（continuation）ごと状態を復元するので、その後のバイトを続けて書いても元と同じ画面になる。
    @Test(arguments: [
        // SGR の途中で区切る。
        (bytes("plain \u{1b}[3"), bytes("1mred\u{1b}[0m end"), "plain red end"),
        // 「日」（E6 97 A5）の途中で区切る。
        (bytes("plain ") + [0xE6, 0x97], [0xA5] + bytes(" end"), "plain 日 end"),
    ])
    func snapshotRestoresAnUnfinishedSequence(head: [UInt8], rest: [UInt8], expected: String) throws {
        let terminal = try VTTerminal(cols: 40, rows: 5, maxScrollback: 100)
        try Self.setContinuationLimit(terminal.handle, 4096)
        terminal.write(head)
        let restored = try Self.decode(try Self.encode(terminal.handle))
        defer { ghostty_terminal_free(restored) }

        terminal.write(rest)
        rest.withUnsafeBufferPointer { ghostty_terminal_vt_write(restored, $0.baseAddress, $0.count) }
        #expect(try Self.format(restored, emit: GHOSTTY_FORMATTER_FORMAT_VT, extras: 0xFFF)
            == Self.format(terminal.handle, emit: GHOSTTY_FORMATTER_FORMAT_VT, extras: 0xFFF))
        let plain = String(decoding: try Self.format(restored, emit: GHOSTTY_FORMATTER_FORMAT_PLAIN), as: UTF8.self)
        #expect(plain == expected)
    }

    // continuation の記録を有効にしていない端末は、シーケンスの途中ではエンコードできない（デーモンは有効にしておく必要がある）。
    @Test func encodingMidSequenceNeedsContinuationTracking() throws {
        let untracked = try VTTerminal(cols: 40, rows: 5, maxScrollback: 100)
        untracked.write(bytes("x\u{1b}[3"))
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let result = ghostty_snapshot_encode_alloc(untracked.handle, nil, &pointer, &length)
        if result == GHOSTTY_SUCCESS { ghostty_free(nil, pointer, length) }
        #expect(result == GHOSTTY_INVALID_VALUE)
    }
}
