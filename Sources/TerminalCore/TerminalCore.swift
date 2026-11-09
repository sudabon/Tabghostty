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

/// 24 bit の RGB 色。
public struct ColorRGB: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `0xRRGGBB` 形式の値から作る。
    public init(hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }

    var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }

    init(_ color: GhosttyColorRgb) {
        self.init(r: color.r, g: color.g, b: color.b)
    }
}

/// Terminal に設定する既定の配色（OSC 10 / 11 / 12 と 256 色パレット）。
public struct TerminalColorConfiguration: Equatable, Sendable {
    public var foreground: ColorRGB
    public var background: ColorRGB
    public var cursor: ColorRGB
    /// 256 色。0〜15 が ANSI 16 色。
    public var palette: [ColorRGB]

    public init(foreground: ColorRGB, background: ColorRGB, cursor: ColorRGB, palette: [ColorRGB]) {
        precondition(palette.count == 256, "palette must have 256 entries")
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.palette = palette
    }
}

/// libghostty-vt の Terminal 1 つを持つ。
///
/// ハンドルはスレッドセーフではないので、`TerminalController`（actor）の中だけで使う
/// （spec: terminal-engine「Serialized access per terminal」）。
public final class VTTerminal {
    let handle: GhosttyTerminal

    /// C の callback が積んだ effect。`takeEffects()` で取り出す。
    fileprivate var pendingEffects: [TerminalEffect] = []
    /// `GHOSTTY_TERMINAL_OPT_SIZE` の callback が返す値（最後に `resize` に渡した値）。
    fileprivate var sizeReport: GhosttySizeReportSize

    private var keyEncoder: KeyEncoder?
    /// マウスエンコーダ（最初のマウスの報告で作る）。
    var mouseEncoder: MouseEncoder?
    /// 選択のジェスチャー（最初の選択の操作で作る）。
    var selectionGesture: SelectionGesture?
    /// 描画用の RenderState（`makeSnapshot` で初めて作る）。
    var renderReader: RenderStateReader?

    /// - Parameters:
    ///   - cols: 列数（1〜65535）
    ///   - rows: 行数（1〜65535）
    ///   - maxScrollback: スクロールバックに残す最大行数（`scrollback_lines`）
    ///   - cellWidthPx: セルの幅（device pixel）。不明なら 0
    ///   - cellHeightPx: セルの高さ（device pixel）。不明なら 0
    public init(cols: Int, rows: Int, maxScrollback: Int, cellWidthPx: Int = 0, cellHeightPx: Int = 0) throws {
        Self.checkGrid(cols: cols, rows: rows)
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
        sizeReport = GhosttySizeReportSize(
            rows: UInt16(rows),
            columns: UInt16(cols),
            cell_width: UInt32(max(0, cellWidthPx)),
            cell_height: UInt32(max(0, cellHeightPx))
        )
        // ここから先で throw しても deinit が走り、ハンドルは解放される。

        try installCallbacks()
        try setMaxScrollback(lines: maxScrollback)
        if cellWidthPx > 0 || cellHeightPx > 0 {
            try resize(cols: cols, rows: rows, cellWidthPx: cellWidthPx, cellHeightPx: cellHeightPx)
            pendingEffects.removeAll()
        }
    }

    deinit {
        keyEncoder = nil
        mouseEncoder = nil
        // ジェスチャーは端末の参照を持っているので、端末より先に解放する。
        selectionGesture = nil
        renderReader = nil
        ghostty_terminal_free(handle)
    }

    // MARK: - 書き込みと effect

    /// VT のバイト列を書き込む。チャンクの境界がエスケープシーケンスや UTF-8 の途中でもよい。
    /// 処理中に出た effect は `takeEffects()` で取り出す。
    public func write<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        let handled: Void? = bytes.withContiguousStorageIfAvailable { buffer in
            writeBuffer(buffer)
        }
        if handled == nil {
            Array(bytes).withUnsafeBufferPointer { writeBuffer($0) }
        }
        // マウスのモードが変わったかもしれない。
        mouseEncoder?.needsSync = true
    }

    /// これまでに溜まった effect を、出た順に取り出す。
    public func takeEffects() -> [TerminalEffect] {
        defer { pendingEffects.removeAll(keepingCapacity: true) }
        return pendingEffects
    }

    // MARK: - サイズ・リセット・設定

    /// 列数・行数（セル単位）。
    public var cols: Int { Int(sizeReport.columns) }
    public var rows: Int { Int(sizeReport.rows) }
    /// 最後に設定したセルのピクセルサイズ（device pixel）。
    public var cellWidthPx: Int { Int(sizeReport.cell_width) }
    public var cellHeightPx: Int { Int(sizeReport.cell_height) }

    /// 列数・行数と、セルのピクセルサイズ（device pixel）を変える。
    /// mode 2048 が有効なら in-band のサイズ報告が effect として積まれる。
    public func resize(cols: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) throws {
        Self.checkGrid(cols: cols, rows: rows)
        let width = UInt32(max(0, cellWidthPx))
        let height = UInt32(max(0, cellHeightPx))
        try Self.check(
            ghostty_terminal_resize(handle, UInt16(cols), UInt16(rows), width, height),
            "ghostty_terminal_resize"
        )
        sizeReport = GhosttySizeReportSize(rows: UInt16(rows), columns: UInt16(cols), cell_width: width, cell_height: height)
        mouseEncoder?.needsSync = true
    }

    /// 完全リセット（RIS 相当）。画面・スクロールバック・モード・選択が初期状態に戻る。サイズと既定の配色は保たれる。
    public func reset() {
        selectionGesture?.reset()
        ghostty_terminal_reset(handle)
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        mouseEncoder?.needsSync = true
    }

    /// スクロールバックに残す最大行数を設定する（`scrollback_lines`）。
    ///
    /// 既定ではバイト数の上限（10,000 バイト、実際には 1 ページ）しか無いので、バイト数の上限を外したうえで
    /// 行数の上限を設定する。libghostty はページ単位で削除するため、内部には設定値より多くの行が残ることがある。
    /// 利用者から見える行数は `scrollbackRows` で上限に丸める。
    public func setMaxScrollback(lines: Int) throws {
        precondition(lines >= 0, "lines must not be negative")
        var unlimitedBytes = UInt.max // size_t の SIZE_MAX
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &unlimitedBytes),
            "ghostty_terminal_set(SCROLLBACK_MAX_BYTES)"
        )
        var maxLines = UInt(lines) // size_t
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &maxLines),
            "ghostty_terminal_set(SCROLLBACK_MAX_LINES)"
        )
        maxScrollback = lines
    }

    /// 設定したスクロールバックの最大行数。
    public private(set) var maxScrollback: Int = 0

    /// スクロールバックに残っている行数（設定した上限で丸めた値）。
    public var scrollbackRows: Int {
        min(rawScrollbackRows, maxScrollback)
    }

    /// libghostty が実際に保持しているスクロールバックの行数（ページ単位の削除のため、上限より多いことがある）。
    var rawScrollbackRows: Int {
        var value = 0
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &value)
        return value
    }

    /// 既定の前景色・背景色・カーソル色と 256 色パレットを設定する。
    public func setColors(_ colors: TerminalColorConfiguration) throws {
        var foreground = colors.foreground.ghostty
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground),
            "ghostty_terminal_set(COLOR_FOREGROUND)"
        )
        var background = colors.background.ghostty
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background),
            "ghostty_terminal_set(COLOR_BACKGROUND)"
        )
        var cursor = colors.cursor.ghostty
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor),
            "ghostty_terminal_set(COLOR_CURSOR)"
        )
        var palette = colors.palette.map(\.ghostty)
        try palette.withUnsafeMutableBufferPointer { buffer in
            try Self.check(
                ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress),
                "ghostty_terminal_set(COLOR_PALETTE)"
            )
        }
    }

    /// 端末のモード（DECSET / SM）の現在値。
    public func mode(_ mode: GhosttyMode) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: mode, value: false)
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else {
            return false
        }
        return config.value
    }

    // MARK: - テキスト

    /// 画面の内容を plain テキスト（エスケープシーケンスなし、行末の空白なし）で返す。
    /// 1 行が 1 つの端末行に対応する（ソフト折り返しは結合しない）。
    public func plainText() throws -> String {
        try format(selection: nil, unwrap: false)
    }

    /// plain テキストにする。
    /// - Parameters:
    ///   - selection: この範囲だけにする。nil なら画面全体
    ///   - unwrap: ソフト折り返しされた行を 1 行に結合する
    func format(selection: UnsafeMutablePointer<GhosttySelection>?, unwrap: Bool) throws -> String {
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
        var unwrap = unwrap
        try Self.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap), "ghostty_formatter_set(UNWRAP)")
        var trim = true
        try Self.check(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim), "ghostty_formatter_set(TRIM)")
        if let selection {
            try Self.check(
                ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, selection),
                "ghostty_formatter_set(SELECTION)"
            )
        }

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

    // MARK: - キー入力

    /// キーイベントを、端末の現在のモード（application cursor など）に従ってバイト列に変換する。
    public func encodeKey(_ key: KeyInput) throws -> [UInt8] {
        if keyEncoder == nil {
            keyEncoder = try KeyEncoder()
        }
        return try keyEncoder!.encode(key, terminal: handle)
    }

    // MARK: - 内部

    private func writeBuffer(_ buffer: UnsafeBufferPointer<UInt8>) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        ghostty_terminal_vt_write(handle, base, buffer.count)
    }

    private func installCallbacks() throws {
        let userdata = Unmanaged.passUnretained(self).toOpaque()
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, userdata),
            "ghostty_terminal_set(USERDATA)"
        )
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(vtWritePty, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(WRITE_PTY)"
        )
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(vtBell, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(BELL)"
        )
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(vtTitleChanged, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(TITLE_CHANGED)"
        )
        try Self.check(
            ghostty_terminal_set(
                handle,
                GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
                unsafeBitCast(vtDesktopNotification, to: UnsafeRawPointer.self)
            ),
            "ghostty_terminal_set(DESKTOP_NOTIFICATION)"
        )
        // OSC 52 などのクリップボードへの書き込み。読み取りの callback は登録しない（常に応答しない。phase2 design D6）。
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(vtClipboardWrite, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(CLIPBOARD_WRITE)"
        )
        // 未登録だと CSI 14/16/18/19 t を黙って無視するので、最後に resize に渡した値を返す。
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(vtSize, to: UnsafeRawPointer.self)),
            "ghostty_terminal_set(SIZE)"
        )
        // DECSCUSR 0（既定に戻す）で点滅するブロックになるようにする（xterm.js の `cursorBlink: true` と同じ見た目）。
        var cursorStyle = GHOSTTY_CURSOR_STYLE_BLOCK
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle),
            "ghostty_terminal_set(DEFAULT_CURSOR_STYLE)"
        )
        var cursorBlink = true
        try Self.check(
            ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink),
            "ghostty_terminal_set(DEFAULT_CURSOR_BLINK)"
        )
    }

    private static func checkGrid(cols: Int, rows: Int) {
        precondition((1...Int(UInt16.max)).contains(cols), "cols out of range: \(cols)")
        precondition((1...Int(UInt16.max)).contains(rows), "rows out of range: \(rows)")
    }

    static func check(_ result: GhosttyResult, _ function: String) throws {
        guard result == GHOSTTY_SUCCESS else {
            throw VTError(function: function, code: result.rawValue)
        }
    }
}

// MARK: - C の callback（値をコピーしてキューに積むだけ。同じ Terminal には触れない）

private func terminal(from userdata: UnsafeMutableRawPointer?) -> VTTerminal? {
    guard let userdata else { return nil }
    return Unmanaged<VTTerminal>.fromOpaque(userdata).takeUnretainedValue()
}

private func string(_ value: GhosttyString) -> String {
    guard let pointer = value.ptr, value.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: value.len), as: UTF8.self)
}

private let vtWritePty: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
    guard let terminal = terminal(from: userdata), let data, length > 0 else { return }
    terminal.pendingEffects.append(.ptyWrite(Array(UnsafeBufferPointer(start: data, count: length))))
}

private let vtBell: GhosttyTerminalBellFn = { _, userdata in
    terminal(from: userdata)?.pendingEffects.append(.bell)
}

private let vtTitleChanged: GhosttyTerminalTitleChangedFn = { _, userdata in
    terminal(from: userdata)?.pendingEffects.append(.titleChanged)
}

private let vtDesktopNotification: GhosttyTerminalDesktopNotificationFn = { _, userdata, notification in
    guard let terminal = terminal(from: userdata), let notification else { return }
    terminal.pendingEffects.append(
        .desktopNotification(title: string(notification.pointee.title), body: string(notification.pointee.body))
    )
}

/// 標準のクリップボードへのテキストの書き込みだけを effect にする。書き込むかどうかは `TerminalController` が phase で決める。
private let vtClipboardWrite: GhosttyTerminalClipboardWriteFn = { _, userdata, write in
    guard let write else { return }
    var reply = GhosttyClipboardWriteReply()
    ghostty_sized_init(&reply, MemoryLayout<GhosttyClipboardWriteReply>.size)
    reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
    defer { write.pointee.reply?(write, &reply) }

    let request = write.pointee
    // macOS には selection / primary のクリップボードが無いので、標準のクリップボードだけを扱う。
    // 内容が空（クリアの要求）なら何もしない。
    guard let terminal = terminal(from: userdata), request.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
          request.contents_len > 0, let contents = request.contents else { return }
    let entries = UnsafeBufferPointer(start: contents, count: request.contents_len)
    guard let text = entries.first(where: { string($0.mime).hasPrefix("text/plain") }) else { return }
    terminal.pendingEffects.append(.clipboardWrite(string(text.data)))
    reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
}

private let vtSize: GhosttyTerminalSizeFn = { _, userdata, out in
    guard let terminal = terminal(from: userdata), let out else { return false }
    out.pointee = terminal.sizeReport
    return true
}
