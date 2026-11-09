import GhosttyVt

/// 端末のモードのうち、入力の振り分けに使うもの。
public struct TerminalInputModes: Equatable, Sendable {
    public var mouseTracking: MouseTracking = .none
    /// alternate screen を表示している。
    public var alternateScreen = false
    /// bracketed paste（DECSET 2004）
    public var bracketedPaste = false
    /// focus reporting（DECSET 1004）
    public var focusReporting = false

    public init() {}
}

/// テキストのペースト（spec: terminal-clipboard「Paste with Command-V」、phase2 design D4）。
public enum PasteText {
    /// bracketed paste の終わりのシーケンス。
    public static let bracketedPasteEnd = "\u{1b}[201~"

    /// 改行（`\r\n` と `\n`）を `\r` にする（Enter と同じ）。
    public static func normalizeLineBreaks(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                // `\r\n` の `\r` はもう入れてある。
                if !afterCR { result.append("\r") }
                afterCR = false
                continue
            }
            result.append(scalar)
            afterCR = scalar == "\r"
        }
        return String(result)
    }

    /// 確認なしで送ってよいか。
    ///
    /// bracketed paste が無効なら、改行を含むテキストはそのまま実行されうるので危険（`ghostty_paste_is_safe`）。
    /// 有効でも、終わりのシーケンスを含むテキストは bracketed paste を抜け出せるので危険。
    public static func isSafe(_ text: String, bracketed: Bool) -> Bool {
        if bracketed {
            return !text.contains(bracketedPasteEnd)
        }
        let data = Array(text.utf8).map { CChar(bitPattern: $0) }
        return data.withUnsafeBufferPointer { buffer in
            ghostty_paste_is_safe(buffer.baseAddress, buffer.count)
        }
    }

    /// 送るバイト列にする（改行を `\r` にし、制御文字を空白に置き換え、bracketed paste なら囲む）。
    public static func encode(_ text: String, bracketed: Bool) -> [UInt8] {
        var data = Array(normalizeLineBreaks(text).utf8).map { CChar(bitPattern: $0) }
        let count = data.count
        return data.withUnsafeMutableBufferPointer { input -> [UInt8] in
            var needed = 0
            let probe = ghostty_paste_encode(input.baseAddress, count, bracketed, nil, 0, &needed)
            guard probe == GHOSTTY_SUCCESS || probe == GHOSTTY_OUT_OF_SPACE, needed > 0 else { return [] }
            var output = [UInt8](repeating: 0, count: needed)
            var written = 0
            let result = ghostty_paste_encode(input.baseAddress, count, bracketed, &output, output.count, &written)
            guard result == GHOSTTY_SUCCESS else { return [] }
            return Array(output.prefix(written))
        }
    }
}

extension VTTerminal {
    // MARK: - モード

    /// 入力の振り分けに使うモード。
    public var inputModes: TerminalInputModes {
        var modes = TerminalInputModes()
        if mode(ghostty_mode_new(1003, false)) {
            modes.mouseTracking = .any
        } else if mode(ghostty_mode_new(1002, false)) {
            modes.mouseTracking = .button
        } else if mode(ghostty_mode_new(1000, false)) {
            modes.mouseTracking = .normal
        } else if mode(ghostty_mode_new(9, false)) {
            modes.mouseTracking = .x10
        }
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        if ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen) == GHOSTTY_SUCCESS {
            modes.alternateScreen = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        }
        modes.bracketedPaste = mode(ghostty_mode_new(2004, false))
        modes.focusReporting = mode(ghostty_mode_new(1004, false))
        return modes
    }

    // MARK: - フォーカス（DECSET 1004）

    /// フォーカスの変化を報告するバイト列。プログラムが focus reporting を有効にしていなければ空。
    public func encodeFocus(_ focused: Bool) -> [UInt8] {
        guard mode(ghostty_mode_new(1004, false)) else { return [] }
        var buffer = [UInt8](repeating: 0, count: 8)
        var written = 0
        let result = ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, &buffer, buffer.count, &written)
        guard result == GHOSTTY_SUCCESS else { return [] }
        return Array(buffer.prefix(written))
    }

    // MARK: - マウス

    /// マウスのイベントを、端末のマウスのモード（報告の種類と形式）に従ってバイト列にする。報告しないイベントなら空。
    public func encodeMouse(_ input: MouseInput) throws -> [UInt8] {
        if mouseEncoder == nil {
            mouseEncoder = try MouseEncoder()
        }
        return try mouseEncoder!.encode(input, terminal: handle)
    }

    // MARK: - ペースト

    /// ペーストするバイト列。確認なしでは送れないテキストで、`allowUnsafe` が false なら nil。
    public func encodePaste(_ text: String, allowUnsafe: Bool) -> [UInt8]? {
        let bracketed = mode(ghostty_mode_new(2004, false))
        guard allowUnsafe || PasteText.isSafe(text, bracketed: bracketed) else { return nil }
        return PasteText.encode(text, bracketed: bracketed)
    }

    // MARK: - viewport のスクロール（spec: terminal-mouse「Scroll wheel and trackpad」）

    /// viewport が最下部（アクティブな領域）にあり、新しい出力に追従している。
    public var isViewportAtBottom: Bool {
        var value = true
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &value)
        return value
    }

    /// スクロールできる範囲と、viewport の位置（行）。
    var scrollbar: GhosttyTerminalScrollbar {
        var value = GhosttyTerminalScrollbar()
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &value)
        return value
    }

    /// viewport の先頭の行の位置（スクロールできる範囲の先頭からの行数）。
    public var viewportOffset: Int { Int(scrollbar.offset) }

    /// viewport を上に動かせる限界（`scrollback_lines` より古い行は見せない。phase2 design D5）。
    ///
    /// libghostty はページ単位でしか古い行を削除しないので、設定より多くの行が残っていることがある。
    var minimumViewportOffset: Int {
        let bar = scrollbar
        let history = Int(bar.total) - Int(bar.len)
        return max(0, history - maxScrollback)
    }

    /// viewport を `rows` 行動かす（上が負）。`scrollback_lines` より古い行と、最下部より先には動かさない。
    /// - Returns: 動いたら true
    @discardableResult
    public func scrollViewport(by rows: Int) -> Bool {
        let bar = scrollbar
        let current = Int(bar.offset)
        let bottom = max(0, Int(bar.total) - Int(bar.len))
        let top = min(minimumViewportOffset, bottom)
        let target = min(max(current + rows, top), bottom)
        guard target != current else {
            // 位置は同じでも、上限より古い行を見せていたら戻す。
            return clampViewportToScrollbackLimit()
        }
        if target == bottom {
            return scrollViewportToBottom()
        }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
        behavior.value.row = target
        return ghostty_terminal_scroll_viewport(handle, behavior) == GHOSTTY_SUCCESS
    }

    /// viewport を最下部に戻し、新しい出力に追従させる。
    /// - Returns: 動いたら true
    @discardableResult
    public func scrollViewportToBottom() -> Bool {
        guard !isViewportAtBottom else { return false }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        return ghostty_terminal_scroll_viewport(handle, behavior) == GHOSTTY_SUCCESS
    }

    /// viewport が `scrollback_lines` より古い行にあれば、見せてよい範囲の先頭まで戻す。
    @discardableResult
    func clampViewportToScrollbackLimit() -> Bool {
        let top = minimumViewportOffset
        guard !isViewportAtBottom, viewportOffset < top else { return false }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
        behavior.value.row = top
        return ghostty_terminal_scroll_viewport(handle, behavior) == GHOSTTY_SUCCESS
    }

    /// 矢印キー（上 / 下）のバイト列。application cursor mode に従う（スクロールを矢印キーに変えるのに使う）。
    func encodeArrow(up: Bool) throws -> [UInt8] {
        let key = KeyInput(
            key: up ? GHOSTTY_KEY_ARROW_UP : GHOSTTY_KEY_ARROW_DOWN,
            action: .press,
            modifiers: [],
            consumedModifiers: [],
            text: "",
            unshiftedCodepoint: 0
        )
        return try encodeKey(key)
    }

    // MARK: - 選択（spec: terminal-clipboard「Text selection」）

    /// 選択の操作を適用する。
    /// - Returns: 端末の選択が変わったら true
    @discardableResult
    public func applySelection(_ input: SelectionInput) throws -> Bool {
        if selectionGesture == nil {
            selectionGesture = try SelectionGesture(terminal: handle)
        }
        let result = selectionGesture!.apply(input)
        if case .autoscrollTick = input.kind {
            // ジェスチャーは viewport を 1 行動かすので、`scrollback_lines` より上には行かせない。
            clampViewportToScrollbackLimit()
        }
        switch result {
        case .unchanged:
            return false
        case .clear:
            return clearSelection()
        case .select(var selection):
            return ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS
        }
    }

    /// 選択をドラッグしている途中で、viewport を自動で動かす必要があるか。
    public var selectionNeedsAutoscroll: Bool {
        guard let gesture = selectionGesture else { return false }
        return gesture.autoscroll != GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
    }

    /// 選択があるか。
    public var hasSelection: Bool {
        var selection = GhosttySelection()
        return ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
    }

    /// 選択を消す。
    /// - Returns: 選択があって消したら true
    @discardableResult
    public func clearSelection() -> Bool {
        guard hasSelection else { return false }
        return ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil) == GHOSTTY_SUCCESS
    }

    /// 選択範囲のテキスト（plain。2 セル幅の文字の空きセルを除き、ソフト折り返しを結合し、行末の空白を削る）。
    /// 選択が無ければ空。
    public func selectionText() throws -> String {
        var selection = GhosttySelection()
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else {
            return ""
        }
        return try format(selection: &selection, unwrap: true)
    }
}

// MARK: - OSC 8 のリンク（spec: terminal-links、phase5 design D6）

extension VTTerminal {
    /// viewport のセルの参照。セルが無ければ nil。参照は次に端末を変更するまでしか有効でない。
    private func viewportRef(x: Int, y: Int) -> GhosttyGridRef? {
        guard x >= 0, y >= 0, x < cols, y < rows else { return nil }
        var ref = GhosttyGridRef()
        let point = GhosttyPoint(
            tag: GHOSTTY_POINT_TAG_VIEWPORT,
            value: GhosttyPointValue(coordinate: GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y)))
        )
        guard ghostty_terminal_grid_ref(handle, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    /// viewport のセル (x, y) に OSC 8 で付けられた URI。無ければ nil。
    public func hyperlinkURI(x: Int, y: Int) -> String? {
        guard var ref = viewportRef(x: x, y: y) else { return nil }
        var length = 0
        let probe = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length)
        guard probe == GHOSTTY_OUT_OF_SPACE || probe == GHOSTTY_SUCCESS, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard ghostty_grid_ref_hyperlink_uri(&ref, &buffer, buffer.count, &length) == GHOSTTY_SUCCESS else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    /// viewport の行 y が、次の行にソフト折り返しで続くか。
    public func viewportRowWraps(_ y: Int) -> Bool {
        guard var ref = viewportRef(x: 0, y: y) else { return false }
        var row: GhosttyRow = 0
        guard ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS else { return false }
        var wraps = false
        _ = ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &wraps)
        return wraps
    }

    /// viewport のセルにある OSC 8 のリンク（同じ URI のセルが続く範囲）。
    public func hyperlink(at point: GridPoint) -> TerminalLink? {
        LinkDetector.hyperlink(
            at: point, cols: cols, rows: rows,
            wraps: { self.viewportRowWraps($0) },
            uri: { self.hyperlinkURI(x: $0, y: $1) }
        )
    }
}

