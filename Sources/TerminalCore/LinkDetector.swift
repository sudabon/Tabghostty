import Foundation

/// viewport の 1 行の中の、リンクのセルの範囲。
public struct LinkSpan: Equatable, Sendable {
    public var row: Int
    public var columns: ClosedRange<Int>

    public init(row: Int, columns: ClosedRange<Int>) {
        self.row = row
        self.columns = columns
    }
}

/// 端末の中のリンク（spec: terminal-links「Link recognition」）。
public struct TerminalLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// OSC 8 でセルに付けられたリンク。
        case hyperlink
        /// 表示されている文字列の中の素の URL。
        case plain
    }

    public var url: String
    public var kind: Kind
    /// リンクのセル（viewport の座標。折り返した行にまたがることがある）。
    public var spans: [LinkSpan]

    public init(url: String, kind: Kind, spans: [LinkSpan]) {
        self.url = url
        self.kind = kind
        self.spans = spans
    }

    public func contains(_ point: GridPoint) -> Bool {
        spans.contains { $0.row == point.y && $0.columns.contains(point.x) }
    }

    /// 開いてよいリンクか（`http` / `https` だけ。spec: terminal-links「Opening links」）。
    public var isOpenable: Bool { LinkDetector.isOpenable(url) }
}

/// リンクの検出（phase5 design D6）。端末に依らない純粋な処理。
public enum LinkDetector {
    /// 開いてよいスキーム。
    public static let openableSchemes: Set<String> = ["http", "https"]

    /// URL を開いてよいか（スキームが `http` / `https` で、ホストがある）。
    public static func isOpenable(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else { return false }
        return openableSchemes.contains(scheme) && !(components.host ?? "").isEmpty
    }

    // MARK: - 素の URL

    /// URL の一部にしない文字（ここで URL が終わる）。
    private static func terminates(_ character: Character) -> Bool {
        if character.isWhitespace { return true }
        switch character {
        case "<", ">", "\"", "'", "`": return true
        default: return false
        }
    }

    /// 末尾にあれば取り除く約物（括弧は、URL の中で対応が取れていないときだけ取り除く）。
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
    private static let closingBrackets: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// 文字の並びの中の `http://` / `https://` の URL の範囲（文字の位置）。
    ///
    /// `https?://` の後に、空白・`<`・`>`・`"`・`'`・バッククォート以外の文字が続く範囲を URL とし、
    /// 末尾の約物（`.` `,` `;` `:` `!` `?`）と、対応の取れていない閉じ括弧（`)` `]` `}`）を取り除く。
    public static func urlRanges(in characters: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var index = 0
        while index < characters.count {
            guard let schemeEnd = schemeEnd(in: characters, at: index) else {
                index += 1
                continue
            }
            var end = schemeEnd
            while end < characters.count, !terminates(characters[end]) {
                end += 1
            }
            end = trimmedEnd(characters, start: index, end: end)
            if end > schemeEnd {
                ranges.append(index..<end)
                index = end
            } else {
                index = schemeEnd
            }
        }
        return ranges
    }

    /// `at` から `http://` / `https://`（大文字小文字は区別しない）が始まっていれば、その直後の位置。
    /// 英数字の直後（`xhttp://` など）は URL の始まりとみなさない。
    private static func schemeEnd(in characters: [Character], at index: Int) -> Int? {
        if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber { return nil }
        for scheme in ["https://", "http://"] {
            let pattern = Array(scheme)
            guard index + pattern.count <= characters.count else { continue }
            if zip(characters[index..<(index + pattern.count)], pattern).allSatisfy({ $0.lowercased() == String($1) }) {
                return index + pattern.count
            }
        }
        return nil
    }

    private static func trimmedEnd(_ characters: [Character], start: Int, end: Int) -> Int {
        var end = end
        while end > start {
            let last = characters[end - 1]
            if trailingPunctuation.contains(last) {
                end -= 1
                continue
            }
            if let opening = closingBrackets[last] {
                let url = characters[start..<end]
                let opened = url.filter { $0 == opening }.count
                let closed = url.filter { $0 == last }.count
                if closed > opened {
                    end -= 1
                    continue
                }
            }
            break
        }
        return end
    }

    /// viewport の行から、`point` のセルにある素の URL を探す（spec: terminal-links「Plain URL」）。
    ///
    /// ソフト折り返しでつながった行（`wrapped[y]` が true なら、行 y は次の行に続く）は 1 行としてつなげて探す。
    /// 空のセルは空白として扱う（URL はそこで終わる）。
    public static func plainLink(at point: GridPoint, rows: [[CellSnapshot]], wrapped: [Bool]) -> TerminalLink? {
        guard point.y >= 0, point.y < rows.count else { return nil }
        func wraps(_ y: Int) -> Bool { y >= 0 && y < wrapped.count && wrapped[y] }
        var first = point.y
        while first > 0, wraps(first - 1) { first -= 1 }
        var last = point.y
        while last + 1 < rows.count, wraps(last) { last += 1 }

        // 論理行の文字と、文字ごとのセル（行と列、2 セル幅なら 2 列）。
        var characters: [Character] = []
        var cells: [(row: Int, columns: ClosedRange<Int>)] = []
        var pointIndex: Int?
        for y in first...last {
            let row = rows[y]
            for (x, cell) in row.enumerated() {
                switch cell.width {
                case .spacerTail, .spacerHead:
                    if y == point.y, x == point.x, let previous = cells.indices.last, cells[previous].row == y,
                       cells[previous].columns.contains(x) {
                        pointIndex = previous
                    }
                    continue
                case .narrow, .wide:
                    break
                }
                let span = cell.width == .wide ? x...min(x + 1, row.count - 1) : x...x
                if y == point.y, span.contains(point.x) { pointIndex = characters.count }
                characters.append(cell.text.isEmpty ? " " : (cell.text.first ?? " "))
                cells.append((y, span))
            }
        }
        guard let pointIndex else { return nil }
        guard let range = urlRanges(in: characters).first(where: { $0.contains(pointIndex) }) else { return nil }
        let url = String(characters[range])
        return TerminalLink(url: url, kind: .plain, spans: spans(of: Array(cells[range])))
    }

    /// セルの並び（行と列の範囲）を、行ごとの範囲にまとめる。
    private static func spans(of cells: [(row: Int, columns: ClosedRange<Int>)]) -> [LinkSpan] {
        var spans: [LinkSpan] = []
        for cell in cells {
            if let last = spans.last, last.row == cell.row, last.columns.upperBound + 1 >= cell.columns.lowerBound {
                spans[spans.count - 1].columns = last.columns.lowerBound...max(last.columns.upperBound, cell.columns.upperBound)
            } else {
                spans.append(LinkSpan(row: cell.row, columns: cell.columns))
            }
        }
        return spans
    }

    // MARK: - OSC 8

    /// `point` のセルに OSC 8 のリンクがあれば、同じ URI のセルが続く範囲（折り返した行もたどる）。
    /// - Parameters:
    ///   - wraps: 行 y が次の行に続く（ソフト折り返し）か
    ///   - uri: セル (x, y) の URI。無ければ nil
    public static func hyperlink(
        at point: GridPoint,
        cols: Int,
        rows: Int,
        wraps: (Int) -> Bool,
        uri: (Int, Int) -> String?
    ) -> TerminalLink? {
        guard point.x >= 0, point.x < cols, point.y >= 0, point.y < rows, let target = uri(point.x, point.y), !target.isEmpty else {
            return nil
        }
        // 前へたどる。
        var start = (x: point.x, y: point.y)
        while true {
            var previous = (x: start.x - 1, y: start.y)
            if previous.x < 0 {
                guard start.y > 0, wraps(start.y - 1) else { break }
                previous = (cols - 1, start.y - 1)
            }
            guard uri(previous.x, previous.y) == target else { break }
            start = previous
        }
        // 後ろへたどる。
        var end = (x: point.x, y: point.y)
        while true {
            var next = (x: end.x + 1, y: end.y)
            if next.x >= cols {
                guard end.y + 1 < rows, wraps(end.y) else { break }
                next = (0, end.y + 1)
            }
            guard uri(next.x, next.y) == target else { break }
            end = next
        }
        var spans: [LinkSpan] = []
        for y in start.y...end.y {
            let first = y == start.y ? start.x : 0
            let last = y == end.y ? end.x : cols - 1
            spans.append(LinkSpan(row: y, columns: first...last))
        }
        return TerminalLink(url: target, kind: .hyperlink, spans: spans)
    }
}
