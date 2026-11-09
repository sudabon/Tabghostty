import AppKit
import CoreText
import TerminalCore

/// IME（spec: terminal-input「Input method composition」、phase2 design D2）。
///
/// - 未確定の文字列はビューの状態として持ち、カーソルの位置に重ねて描く。Terminal には書き込まない。
/// - 確定した文字列（`insertText`）は、`classifyKey` を通さずにテキストとして送る（`¥` の書き換えはしない）。
/// - 変換候補のウィンドウは、カーソルのセルに出す（`firstRect`）。
extension TerminalView: @preconcurrency NSTextInputClient {
    // MARK: - 文字列の受け取り

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainString(string)
        isRestoredComposition = false
        let wasComposing = hasMarkedText()
        if wasComposing {
            setMarkedTextValue("", selectedRange: NSRange(location: 0, length: 0))
        }
        guard !text.isEmpty else { return }
        if insertedTexts != nil, !wasComposing {
            // keyDown の中で、そのキーが作った文字が届いた。キーと一緒にエンコーダに渡す（keyDown 側で送る）。
            insertedTexts?.append(text)
            return
        }
        // IME の確定、絵文字ピッカーなど。テキストとしてそのまま送る。
        controller?.enqueueText(text)
        restartBlink()
    }

    public override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if insertedTexts != nil {
            markedTextChangedDuringInterpret = true
        }
        isRestoredComposition = false
        setMarkedTextValue(Self.plainString(string), selectedRange: selectedRange)
    }

    public func unmarkText() {
        // 未確定の文字列を捨てる（確定するときは insertText が先に届く）。
        isRestoredComposition = false
        setMarkedTextValue("", selectedRange: NSRange(location: 0, length: 0))
    }

    // MARK: - タブを切り替えたときの未確定の文字列（phase3 design D1）

    /// 別のタブから戻ってきたときに、預けてあった未確定の文字列を表示する。
    ///
    /// IME の変換は切り替えたときに終わっているので、IME はこの文字列を知らない。次のキーで
    /// `handleKeyForRestoredComposition(_:)` が確定・取り消し・編集をする。
    func restoreComposition(_ saved: ComposingText) {
        guard !saved.text.isEmpty else { return }
        setMarkedTextValue(saved.text, selectedRange: NSRange(location: saved.selectedLocation, length: saved.selectedLength))
        isRestoredComposition = true
    }

    /// 戻した未確定の文字列があるときのキー。
    ///
    /// - Return / Enter: 確定して送る（変換中の Enter と同じく、改行は送らない）
    /// - Escape: 取り消す（何も送らない）
    /// - Backspace: 最後の 1 文字を消す
    /// - それ以外: 確定して送り、そのキーは通常どおりに処理する
    ///
    /// - Returns: キーをここで処理したら true（false なら、呼び出し側で通常どおりに処理する）
    func handleKeyForRestoredComposition(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x24, 0x4C:
            commitRestoredComposition()
            return true
        case 0x35:
            unmarkText()
            return true
        case 0x33:
            var text = markedText
            text.removeLast()
            if text.isEmpty {
                unmarkText()
            } else {
                setMarkedTextValue(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            }
            return true
        default:
            commitRestoredComposition()
            return false
        }
    }

    private func commitRestoredComposition() {
        let text = markedText
        unmarkText()
        controller?.enqueueText(text)
    }

    /// 変換を打ち切り、未確定の文字列を捨てる（フォーカスを失ったときなど）。
    func discardMarkedText() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        unmarkText()
    }

    /// 変換中のキーを IME が処理しなかったときに AppKit が呼ぶ。キーは keyDown の側で送るので、ここでは何もしない
    /// （何もしないと既定の動作でビープが鳴る）。
    public override func doCommand(by selector: Selector) {}

    // MARK: - 状態

    public func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    public func markedRange() -> NSRange {
        guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (markedText as NSString).length)
    }

    public func selectedRange() -> NSRange {
        guard hasMarkedText() else { return NSRange(location: NSNotFound, length: 0) }
        return markedSelectedRange
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment]
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // 端末の内容は IME に見せない。未確定の文字列の中だけを返す。
        guard hasMarkedText(), range.location != NSNotFound else { return nil }
        let whole = markedText as NSString
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: whole.length))
        guard clamped.length > 0 || clamped.location == range.location else { return nil }
        actualRange?.pointee = clamped
        return NSAttributedString(string: whole.substring(with: clamped))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    /// 変換候補のウィンドウを出す位置（スクリーン座標）。カーソルのセルから、未確定の文字列の `range` の位置まで進めた矩形。
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let location = range.location == NSNotFound ? 0 : range.location
        actualRange?.pointee = NSRange(location: location, length: range.length)
        let rect = markedTextRect(upTo: location)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: - 未確定の文字列の配置と描画

    /// 未確定の文字列を置く位置（カーソルのセル）。カーソルが viewport の外なら左上。
    private var markedTextOrigin: GridPoint {
        guard let cursor, cursor.y >= 0, cursor.y < gridRows else { return GridPoint(x: 0, y: 0) }
        let x = cursor.onWideTail ? max(0, cursor.x - 1) : cursor.x
        return GridPoint(x: min(max(0, x), gridColumns - 1), y: cursor.y)
    }

    /// 未確定の文字列を書記素ごとに並べた位置（列のずれ）と幅。
    private var markedTextLayout: [(text: String, column: Int, width: Int, utf16Offset: Int)] {
        var layout: [(String, Int, Int, Int)] = []
        var column = 0
        var offset = 0
        for character in markedText {
            let width = terminalCellWidth(of: character)
            layout.append((String(character), column, width, offset))
            column += width
            offset += character.utf16.count
        }
        return layout
    }

    /// カーソルのセルから、未確定の文字列の UTF-16 の位置 `location` までの文字のセル（ビューの座標）。
    func markedTextRect(upTo location: Int) -> NSRect {
        let origin = markedTextOrigin
        var columns = 0
        for item in markedTextLayout where item.utf16Offset < location {
            columns = item.column + item.width
        }
        let column = min(origin.x + columns, gridColumns - 1)
        return cellRect(x: column, y: origin.y)
    }

    private func setMarkedTextValue(_ text: String, selectedRange: NSRange) {
        guard text != markedText || selectedRange != markedSelectedRange else { return }
        invalidateMarkedText()
        markedText = text
        markedSelectedRange = selectedRange
        invalidateMarkedText()
        // 変換中はカーソルを点滅させない（未確定の文字列を重ねて描く）。
        restartBlink()
    }

    /// 未確定の文字列を描く行を描き直す。
    private func invalidateMarkedText() {
        guard hasMarkedText() else { return }
        let origin = markedTextOrigin
        renderer.invalidate(rowRect(origin.y))
    }

    /// 未確定の文字列を、書記素ごとに置くセル（右端を越える分は含めない）。描画の実装が読む。
    var markedTextCells: [MarkedTextCell] {
        guard hasMarkedText() else { return [] }
        let origin = markedTextOrigin
        let selected = markedSelectedRange
        var cells: [MarkedTextCell] = []
        for item in markedTextLayout {
            let column = origin.x + item.column
            // 右端を越える分は描かない。
            guard column + item.width <= gridColumns else { break }
            cells.append(MarkedTextCell(
                text: item.text,
                x: column,
                y: origin.y,
                width: item.width,
                isSelected: selected.length > 0 && NSLocationInRange(item.utf16Offset, selected)
            ))
        }
        return cells
    }

    private static func plainString(_ value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let string = value as? String { return string }
        return ""
    }
}
