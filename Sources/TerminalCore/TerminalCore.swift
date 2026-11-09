// libghostty-vt の Swift ラッパー。C API 名は README.md の対応表を正とする。
import GhosttyVt

/// libghostty-vt の呼び出しが失敗したことを表す。
public struct VTError: Error, Equatable, CustomStringConvertible {
    /// 失敗した C 関数の名前。
    public let function: String
    /// `GhosttyResult` の値（負の数）。
    public let code: Int32

    public var description: String { "\(function) failed with GhosttyResult \(code)" }
}

/// libghostty-vt の Terminal 1 つを持つ。
///
/// Phase 0 の時点では、生成・書き込み・plain テキストの取り出しだけを提供する。
/// ハンドルはスレッドセーフではないので、利用側で 1 つの実行コンテキストに閉じ込めること
/// （Phase 1 で actor に閉じ込める）。
public final class VTTerminal {
    private let handle: GhosttyTerminal

    /// - Parameters:
    ///   - cols: 列数（1〜65535）
    ///   - rows: 行数（1〜65535）
    ///   - maxScrollback: スクロールバックに残す最大行数（`scrollback_lines`）
    public init(cols: Int, rows: Int, maxScrollback: Int) throws {
        precondition((1...Int(UInt16.max)).contains(cols), "cols out of range: \(cols)")
        precondition((1...Int(UInt16.max)).contains(rows), "rows out of range: \(rows)")
        precondition(maxScrollback >= 0, "maxScrollback must not be negative")

        var created: GhosttyTerminal?
        try Self.check(
            ghostty_terminal_new(nil, &created, UInt16(cols), UInt16(rows)),
            "ghostty_terminal_new"
        )
        guard let created else {
            throw VTError(function: "ghostty_terminal_new", code: GHOSTTY_INVALID_VALUE.rawValue)
        }
        handle = created

        do {
            // 既定のスクロールバック上限は 10,000 バイト（実際には 1 ページ）なので、
            // バイト数の上限を外し、行数の上限で `scrollback_lines` を表す（README の対応表を参照）。
            var unlimitedBytes = UInt.max // size_t の SIZE_MAX
            try Self.check(
                ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimitedBytes),
                "ghostty_terminal_set(SCROLLBACK_MAX_BYTES)"
            )
            var lines = UInt(maxScrollback) // size_t
            try Self.check(
                ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines),
                "ghostty_terminal_set(SCROLLBACK_MAX_LINES)"
            )
        } catch {
            ghostty_terminal_free(handle)
            throw error
        }
    }

    deinit {
        ghostty_terminal_free(handle)
    }

    /// VT のバイト列を書き込む。チャンクの境界がエスケープシーケンスや UTF-8 の途中でもよい。
    public func write<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        let handled: Void? = bytes.withContiguousStorageIfAvailable { buffer in
            writeBuffer(buffer)
        }
        if handled == nil {
            Array(bytes).withUnsafeBufferPointer { writeBuffer($0) }
        }
    }

    /// 画面の内容を plain テキスト（エスケープシーケンスなし、行末の空白なし）で返す。
    /// 1 行が 1 つの端末行に対応する（ソフト折り返しは結合しない）。
    public func plainText() throws -> String {
        var formatter: GhosttyFormatter?
        try Self.check(
            ghostty_formatter_terminal_new(nil, &formatter, handle),
            "ghostty_formatter_terminal_new"
        )
        guard let formatter else {
            throw VTError(function: "ghostty_formatter_terminal_new", code: GHOSTTY_INVALID_VALUE.rawValue)
        }
        defer { ghostty_formatter_free(formatter) }

        // 既定値は PLAIN・UNWRAP=false・TRIM=true だが、意図を明示しておく。
        var emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        try Self.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit), "ghostty_formatter_set(EMIT)")
        var unwrap = false
        try Self.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap), "ghostty_formatter_set(UNWRAP)")
        var trim = true
        try Self.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim), "ghostty_formatter_set(TRIM)")

        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try Self.check(
            ghostty_formatter_format_alloc(formatter, nil, &pointer, &length),
            "ghostty_formatter_format_alloc"
        )
        defer { ghostty_free(nil, pointer, length) }
        guard let pointer, length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private func writeBuffer(_ buffer: UnsafeBufferPointer<UInt8>) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        ghostty_terminal_vt_write(handle, base, buffer.count)
    }

    private static func check(_ result: GhosttyResult, _ function: String) throws {
        guard result == GHOSTTY_SUCCESS else {
            throw VTError(function: function, code: result.rawValue)
        }
    }
}
