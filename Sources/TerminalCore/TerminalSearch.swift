import GhosttyVt

/// 検索の一致 1 つ（spec: terminal-search「Search scope and matching」）。
///
/// 行は画面の座標（`GHOSTTY_POINT_TAG_SCREEN`。残っているいちばん古いスクロールバックの行が 0）。
/// viewport の位置（`VTTerminal.viewportOffset`）と同じ座標なので、引けば viewport の行になる。
public struct SearchMatch: Equatable, Sendable {
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    /// 最後のセル（含む）。
    public var endColumn: Int

    public init(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        self.startRow = startRow
        self.startColumn = startColumn
        self.endRow = endRow
        self.endColumn = endColumn
    }
}

/// viewport の 1 行の中の、検索の一致の列の範囲。
public struct SearchHighlight: Equatable, Sendable {
    public var columns: ClosedRange<Int>
    /// 今の一致（ほかの一致と違う色で描く）。
    public var isCurrent: Bool

    public init(columns: ClosedRange<Int>, isCurrent: Bool) {
        self.columns = columns
        self.isCurrent = isCurrent
    }
}

/// 検索の状態（検索バーの `n / m`）。
public struct SearchStatus: Equatable, Sendable {
    public var query: String
    public var total: Int
    /// 今の一致の番号（0 始まり、上から）。一致が無ければ nil。
    public var current: Int?

    public init(query: String, total: Int, current: Int?) {
        self.query = query
        self.total = total
        self.current = current
    }

    public static let empty = SearchStatus(query: "", total: 0, current: nil)

    /// 検索バーに出す文字列（`3 / 12`、一致が無ければ `0 / 0`）。
    public var label: String {
        guard let current, total > 0 else { return "0 / 0" }
        return "\(current + 1) / \(total)"
    }
}

/// libghostty の検索（`ghostty_search_*`。Sources/TerminalCore/README.md の対応表）。`VTTerminal` が持ち、同じ actor の中で使う。
final class TerminalSearcher {
    private let search: GhosttySearch
    private let terminal: GhosttyTerminal
    private var buffer: [GhosttySelection] = []

    init(terminal: GhosttyTerminal) throws {
        self.terminal = terminal
        var created: GhosttySearch?
        try VTTerminal.check(ghostty_search_new(nil, &created, terminal), "ghostty_search_new")
        guard let created else { throw VTError(function: "ghostty_search_new", code: GHOSTTY_INVALID_VALUE.rawValue) }
        search = created
        // viewport は Swift 側で動かす（`scrollback_lines` より古い一致に移らないように）。
        var scroll = GHOSTTY_SEARCH_SCROLL_NONE
        _ = ghostty_search_set(search, GHOSTTY_SEARCH_OPT_SELECT_SCROLL, &scroll)
    }

    deinit {
        ghostty_search_free(search)
    }

    /// `needle` を探し、一致を返す（libghostty の順のまま。新しいものから）。空なら検索をやめる。
    ///
    /// 一致は ASCII の英字だけ大文字小文字を区別しない（libghostty の仕様。Ghostty 本体と同じ）。
    func matches(for needle: String) throws -> [SearchMatch] {
        try setNeedle(needle)
        guard !needle.isEmpty else { return [] }
        try VTTerminal.check(ghostty_search_run(search), "ghostty_search_run")

        var selections = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        var result = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_MATCHES, &selections)
        if result == GHOSTTY_OUT_OF_SPACE || selections.len > buffer.count {
            buffer = [GhosttySelection](repeating: GhosttySelection(), count: max(selections.len, buffer.count * 2))
        }
        guard selections.len > 0 || result == GHOSTTY_OUT_OF_SPACE else { return [] }
        result = buffer.withUnsafeMutableBufferPointer { storage -> GhosttyResult in
            selections = GhosttySelectionBuffer(ptr: storage.baseAddress, cap: storage.count, len: 0)
            return ghostty_search_get(search, GHOSTTY_SEARCH_DATA_MATCHES, &selections)
        }
        try VTTerminal.check(result, "ghostty_search_get(MATCHES)")

        var matches: [SearchMatch] = []
        matches.reserveCapacity(selections.len)
        for index in 0..<selections.len {
            var selection = buffer[index]
            var start = GhosttyPointCoordinate()
            var end = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(terminal, &selection.start, GHOSTTY_POINT_TAG_SCREEN, &start) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(terminal, &selection.end, GHOSTTY_POINT_TAG_SCREEN, &end) == GHOSTTY_SUCCESS else {
                continue
            }
            matches.append(SearchMatch(startRow: Int(start.y), startColumn: Int(start.x), endRow: Int(end.y), endColumn: Int(end.x)))
        }
        return matches
    }

    private func setNeedle(_ needle: String) throws {
        let bytes = Array(needle.utf8)
        let result = bytes.withUnsafeBufferPointer { buffer -> GhosttyResult in
            guard !bytes.isEmpty else { return ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, nil) }
            var string = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
            return ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, &string)
        }
        try VTTerminal.check(result, "ghostty_search_set(NEEDLE)")
    }
}

extension VTTerminal {
    /// `needle` を画面とスクロールバックから探す（spec: terminal-search「Search scope and matching」）。
    ///
    /// - 大文字小文字を区別しない（ASCII の英字。libghostty の仕様）。
    /// - 最新の `scrollback_lines` 行より古い行で始まる一致は含めない（libghostty はページ単位で古い行を消すので、
    ///   内部には上限より古い行が残っていることがある。phase1 design D2）。
    /// - 一致は上（古い行）から順に並べる。
    public func search(_ needle: String) throws -> [SearchMatch] {
        if searcher == nil {
            guard !needle.isEmpty else { return [] }
            searcher = try TerminalSearcher(terminal: handle)
        }
        let oldest = minimumViewportOffset
        return try searcher!.matches(for: needle)
            .filter { $0.startRow >= oldest }
            .sorted { ($0.startRow, $0.startColumn) < ($1.startRow, $1.startColumn) }
    }

    /// 検索をやめる（libghostty が端末の中に持っている追跡の情報を手放す）。
    public func endSearch() {
        searcher = nil
    }

    /// 一致が viewport に入るように動かす。もう見えていれば動かさない。
    /// - Returns: 動いたら true
    @discardableResult
    public func scrollToShow(_ match: SearchMatch) -> Bool {
        let top = viewportOffset
        let visibleRows = rows
        if match.startRow >= top, match.endRow < top + visibleRows { return false }
        // 一致が viewport の真ん中あたりに来るようにする（上限と最下部の間に収まる）。
        let target = max(0, match.startRow - visibleRows / 2)
        return scrollViewport(by: target - top)
    }
}
