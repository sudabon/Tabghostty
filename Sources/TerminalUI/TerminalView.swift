import AppKit
import CoreText
import QuartzCore
import TerminalCore

/// セッション 1 つの端末を Core Text で描くビュー（design D6、spec: terminal-rendering / terminal-input）。
///
/// - 描画データは `TerminalController` から値型の `FrameSnapshot` で受け取る。取りに行くのは
///   display link の 1 フレームにつき高々 1 回で、変化があるときだけ（design D1）。
/// - 変化した行（カーソルの点滅ならカーソルのセル）だけを再描画する。
/// - ビューの大きさからグリッドの大きさを求め、50 ms 変化が止まってから `onGridChange` で知らせる。
/// - キー入力は `classifyKey` で振り分ける（phase2 design D1）。IME は `TerminalView+TextInput.swift`、
///   マウス・スクロール・選択は `TerminalView+Mouse.swift`、コピー・ペーストは `TerminalView+Clipboard.swift`。
@MainActor
public final class TerminalView: NSView {
    public private(set) var fonts: FontResolver
    /// `font_family` の値（CSS 風のカンマ区切り。`fonts.familyName` は選ばれた 1 つ）。
    public private(set) var fontFamily: String
    public private(set) var palette: Palette
    public private(set) var metrics: CellMetrics

    /// 表示するセッションの端末。差し替えると全体を描き直す（phase3 design D1）。
    ///
    /// 選択範囲と viewport の位置は、各セッションの端末（ライブラリ）が持っているので、切り替えても失われない。
    /// IME の未確定の文字列は、前の端末に預けてから、新しい端末に預けてあったものを戻す。
    public var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            if let oldValue, hasMarkedText() {
                oldValue.saveComposition(ComposingText(
                    text: markedText,
                    selectedLocation: markedSelectedRange.location,
                    selectedLength: markedSelectedRange.length
                ))
            }
            // キーボードフォーカスは、表示しているセッションのもの。
            if reportedFocus == true {
                oldValue?.enqueueFocus(false)
                controller?.enqueueFocus(true)
            }
            resetModel()
            resetInputState()
            if let saved = controller?.takeSavedComposition() {
                restoreComposition(saved)
            }
        }
    }

    /// コードのプレフィックスの判定（キー入力の段階 0。phase3 design D4）。true を返したキーは端末に送らない。
    public var keyChordHandler: ((KeyStroke) -> Bool)?

    /// 入力の設定（config の `shift_enter_newline` と `copy_on_select`）。
    public var inputSettings = TerminalInputSettings()
    /// コピーとペーストに使う pasteboard（テストで差し替える）。
    public var pasteboard: NSPasteboard = .general
    /// 危険なペーストを送ってよいか、利用者に確かめる（テストで差し替える）。nil なら確認のシートを出す。
    public var confirmUnsafePaste: ((_ text: String, _ completion: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// ペーストした・ドロップした画像を添付する（`ImageAttachService`。spec: image-attach）。
    /// nil なら、画像は扱わない（Command-V はテキストだけをペーストする）。
    public var imageAttachHandler: (([AttachableImage]) -> Void)?
    /// ドロップを受け付けている間に出す枠の色（chrome トークンの accent）。
    public var dropHighlightColor: NSColor = .controlAccentColor {
        didSet { dropFrame.color = dropHighlightColor }
    }
    /// ドロップを受け付けている間に出す枠（`TerminalView+ImageDrop.swift`）。
    let dropFrame = DropFrameView()

    /// グリッドのサイズが変わった（デバウンス後）。
    public var onGridChange: ((TerminalController.GridSize) -> Void)?
    /// キーボードフォーカスを得た。
    public var onFocus: (() -> Void)?

    /// 最後に知らせたグリッドのサイズ。
    public private(set) var appliedGrid: TerminalController.GridSize?

    // 描画のモデル（最後に受け取ったスナップショットの内容）
    private var cols = 0
    private var rows = 0
    private var cells: [[CellSnapshot]] = []
    /// 行ごとの選択されている列の範囲。
    private var rowSelections: [ClosedRange<Int>?] = []
    private var frameColors: FrameColors?
    private(set) var cursor: CursorSnapshot?

    // IME（`TerminalView+TextInput.swift`）
    /// 未確定の文字列。空なら変換していない。
    var markedText = ""
    /// 未確定の文字列の中で選ばれている範囲（UTF-16）。
    var markedSelectedRange = NSRange(location: 0, length: 0)
    /// `.interpret` のキーを `interpretKeyEvents` に渡している間に、`insertText` で届いた文字列。それ以外のときは nil。
    var insertedTexts: [String]?
    /// `.interpret` のキーを渡している間に、未確定の文字列が変わった。
    var markedTextChangedDuringInterpret = false
    /// 未確定の文字列が、別のタブから戻したもの（IME はこの文字列を知らない）。
    var isRestoredComposition = false
    /// コードの判定で使ったキー（離したことも端末に送らない）。
    private var chordConsumedKeyCodes: Set<UInt16> = []
    /// 最後に報告したキーボードフォーカス。
    var reportedFocus: Bool?

    // マウス（`TerminalView+Mouse.swift`）
    var pointerGesture = PointerGesture.none
    var pressedButtons: Set<MouseInput.Button> = []
    var lastDragPoint: CGPoint = .zero
    var autoscrollTimer: Timer?
    var scrollAccumulator = ScrollAccumulator()
    var mouseTrackingArea: NSTrackingArea?

    private var displayLink: CADisplayLink?
    private var snapshotInFlight = false
    private var needsFullSnapshot = true

    private var blinkTimer: Timer?
    private var blinkVisible = true
    private var resizeTask: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []

    private var colorCache: [RGBAKey: CGColor] = [:]
    private var contrastCache: [ColorPair: ColorRGB] = [:]

    /// カーソルの点滅間隔（SPEC: 約 530 ms）。
    static let blinkInterval: TimeInterval = 0.53

    public init(fontFamily: String, fontSize: CGFloat, palette: Palette) {
        self.fontFamily = fontFamily
        fonts = FontResolver(fontFamily: fontFamily, size: fontSize)
        self.palette = palette
        metrics = CellMetrics.make(font: fonts.regular, scale: NSScreen.main?.backingScaleFactor ?? 2)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setUpImageDrop()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: - ウィンドウとの関係

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        displayLink?.invalidate()
        displayLink = nil

        guard let window else {
            stopBlinking()
            return
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.focusDidChange() }
            })
        }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateMetrics()
        scheduleGridUpdate()
        focusDidChange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Retina と外部モニタの間を移ったら、セルの寸法とグリフを計算し直す（device pixel が変わる）。
        updateMetrics()
        scheduleGridUpdate()
        needsDisplay = true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleGridUpdate()
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        // この時点では `window.firstResponder` はまだ変わっていないので、結果を渡す。
        focusDidChange(isFirstResponder: accepted)
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            // 変換の途中でフォーカスを失ったら、未確定の文字列は捨てる。
            discardMarkedText()
        }
        focusDidChange(isFirstResponder: !resigned)
        return resigned
    }

    /// ウィンドウがキーで、このビューが first responder か。
    public var hasKeyboardFocus: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    // MARK: - キー入力（spec: terminal-input、phase2 design D1）

    public override func keyDown(with event: NSEvent) {
        let stroke = KeyStroke(event: event, phase: .down, isComposing: hasMarkedText())
        // 0. コード（Ctrl+J など）。端末へのキー送信より前に判定する（spec: keyboard-shortcuts）。
        if let keyChordHandler, keyChordHandler(stroke) {
            chordConsumedKeyCodes.insert(event.keyCode)
            return
        }
        if isRestoredComposition, hasMarkedText(), handleKeyForRestoredComposition(event) {
            restartBlink()
            return
        }
        switch classifyKey(KeyStroke(event: event, phase: .down, isComposing: hasMarkedText()), settings: inputSettings.keySettings) {
        case .ignore, .systemShortcut:
            // Command 付きのキーはメニューのショートカットに任せ、セッションには送らない。
            return
        case .inputMethod:
            // 変換中のキーは IME のもの。確定した文字列だけが insertText で届く。
            interpretKeyEvents([event])
        case .send(let text):
            controller?.enqueueText(text)
        case .encode:
            if let input = KeyInput(event: event) {
                controller?.enqueueKey(input)
            }
        case .interpret:
            interpret(event)
        }
        restartBlink()
    }

    /// `interpretKeyEvents` に渡し、`insertText` で届いた文字を付けてキーエンコーダに渡す
    /// （Option で合成した文字・デッドキー・IME の変換の開始もここを通る）。
    private func interpret(_ event: NSEvent) {
        insertedTexts = []
        markedTextChangedDuringInterpret = false
        interpretKeyEvents([event])
        let texts = insertedTexts ?? []
        insertedTexts = nil
        // IME が変換を始めた（デッドキーを含む）。確定するまで何も送らない。
        guard !hasMarkedText(), !markedTextChangedDuringInterpret else { return }
        guard !texts.isEmpty else {
            // 文字が届かなかった（キーの割り当てでコマンドに変わったなど）。キーとしてエンコーダに渡す。
            if let input = KeyInput(event: event) {
                controller?.enqueueKey(input)
            }
            return
        }
        for text in texts {
            if let input = KeyInput(event: event, text: text) {
                controller?.enqueueKey(input)
            } else {
                controller?.enqueueText(text)
            }
        }
    }

    public override func keyUp(with event: NSEvent) {
        if chordConsumedKeyCodes.remove(event.keyCode) != nil {
            return
        }
        // 離したことは、kitty keyboard protocol で求められたときだけエンコーダが出力する。
        let stroke = KeyStroke(event: event, phase: .up, isComposing: hasMarkedText())
        guard classifyKey(stroke, settings: inputSettings.keySettings) == .encode, let input = KeyInput(event: event) else { return }
        controller?.enqueueKey(input)
    }

    public override func flagsChanged(with event: NSEvent) {
        // 修飾キーそのものを押した / 離した（kitty keyboard protocol の「すべてのキーを報告する」で使う）。
        guard let flag = KeyInput.modifier(forKeyCode: event.keyCode) else { return }
        let modifiers = KeyInput.Modifiers(event.modifierFlags)
        let pressed = modifiers.contains(flag)
        let stroke = KeyStroke(
            phase: pressed ? .down : .up, keyCode: event.keyCode, characters: "", modifiers: modifiers, isComposing: hasMarkedText()
        )
        guard classifyKey(stroke, settings: inputSettings.keySettings) == .encode,
              let input = KeyInput.mac(
                  keyCode: event.keyCode, characters: "", charactersIgnoringModifiers: "", unshiftedCharacters: "",
                  modifiers: modifiers, action: pressed ? .press : .release
              ) else { return }
        controller?.enqueueKey(input)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Ctrl 付きのキー（Ctrl+Tab など）は keyDown に届かないことがあるので、ここで端末に送る。
        guard event.type == .keyDown, window?.firstResponder === self,
              event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    // MARK: - 設定の変更

    /// 配色を差し替える（spec: color-scheme「Scheme applies everywhere」）。
    ///
    /// 端末の既定の色（fg / bg / cursor / 256 色）は、各セッションの `TerminalController.setColors` で差し替える
    /// （スナップショットの色に反映される）。ここでは、まだスナップショットが無いときの色と選択色を変える。
    public func setPalette(_ palette: Palette) {
        guard palette != self.palette else { return }
        self.palette = palette
        contrastCache.removeAll()
        needsDisplay = true
    }

    /// フォントを差し替える（`font_family` / `font_size`。spec: settings-window「Configuration changes take effect without restart」）。
    /// セルの寸法を計算し直し、グリッドのサイズが変われば `onGridChange` で知らせる（全セッションに `resize` を送る）。
    public func setFont(family: String, size: CGFloat) {
        guard family != fontFamily || size != fonts.size else { return }
        fontFamily = family
        fonts = FontResolver(fontFamily: family, size: size)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metrics = CellMetrics.make(font: fonts.regular, scale: scale)
        contrastCache.removeAll()
        needsDisplay = true
        scheduleGridUpdate()
    }

    // MARK: - グリッドのサイズ（spec: terminal-rendering「Grid size follows the view」）

    private func updateMetrics() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let next = CellMetrics.make(font: fonts.regular, scale: scale)
        guard next != metrics else { return }
        metrics = next
        needsDisplay = true
    }

    private func scheduleGridUpdate() {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: GridGeometry.debounce)
            guard !Task.isCancelled else { return }
            self?.applyGridSize()
        }
    }

    private func applyGridSize() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let grid = GridGeometry.terminalGrid(viewSize: bounds.size, cell: metrics)
        // 1 セル未満の変化では何もしない。
        guard GridGeometry.needsUpdate(previous: appliedGrid, next: grid) else { return }
        appliedGrid = grid
        onGridChange?(grid)
    }

    // MARK: - スナップショットの取得

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let controller, !snapshotInFlight else { return }
        guard needsFullSnapshot || controller.needsRender else { return }
        snapshotInFlight = true
        let full = needsFullSnapshot
        needsFullSnapshot = false
        Task { [weak self] in
            let snapshot = await controller.makeSnapshot(forceFull: full)
            guard let self else { return }
            self.snapshotInFlight = false
            guard self.controller === controller, let snapshot else { return }
            self.apply(snapshot)
        }
    }

    private func resetModel() {
        cols = 0
        rows = 0
        cells = []
        rowSelections = []
        cursor = nil
        frameColors = nil
        needsFullSnapshot = true
        needsDisplay = true
    }

    /// スナップショットをモデルに反映し、変わったところだけ再描画を頼む。
    func apply(_ snapshot: FrameSnapshot) {
        var redrawAll = snapshot.isFull
        if snapshot.cols != cols || snapshot.rows != rows {
            cols = snapshot.cols
            rows = snapshot.rows
            cells = Array(repeating: Array(repeating: .blank, count: cols), count: rows)
            rowSelections = Array(repeating: nil, count: rows)
            redrawAll = true
        }
        if snapshot.colors != frameColors {
            frameColors = snapshot.colors
            contrastCache.removeAll()
            redrawAll = true
        }

        var dirtyRows = IndexSet()
        for row in snapshot.dirtyRows where row.y >= 0 && row.y < rows {
            var rowCells = row.cells
            if rowCells.count < cols {
                rowCells.append(contentsOf: repeatElement(CellSnapshot.blank, count: cols - rowCells.count))
            } else if rowCells.count > cols {
                rowCells.removeLast(rowCells.count - cols)
            }
            cells[row.y] = rowCells
            rowSelections[row.y] = snapshot.selections[row.y]
            dirtyRows.insert(row.y)
        }

        if snapshot.cursor != cursor {
            if let old = cursor { setNeedsDisplay(cursorRect(old)) }
            cursor = snapshot.cursor
            if let new = cursor { setNeedsDisplay(cursorRect(new)) }
            restartBlink()
        }

        if redrawAll {
            needsDisplay = true
        } else {
            for y in dirtyRows {
                setNeedsDisplay(rowRect(y))
            }
        }
    }

    // MARK: - 座標

    private var padding: CGFloat { GridGeometry.padding }

    /// グリッドの列数・行数（最後のスナップショット。まだ無ければビューのグリッド）。
    var gridColumns: Int { cols > 0 ? cols : appliedGrid?.cols ?? 1 }
    var gridRows: Int { rows > 0 ? rows : appliedGrid?.rows ?? 1 }

    func rowRect(_ y: Int) -> NSRect {
        // 右端の余白まで含める（列数に収まらない端数の部分も背景で塗る）。
        NSRect(x: 0, y: padding + CGFloat(y) * metrics.height, width: bounds.width, height: metrics.height)
    }

    func cellRect(x: Int, y: Int, width: Int = 1) -> NSRect {
        NSRect(
            x: padding + CGFloat(x) * metrics.width,
            y: padding + CGFloat(y) * metrics.height,
            width: CGFloat(width) * metrics.width,
            height: metrics.height
        )
    }

    private func cursorRect(_ cursor: CursorSnapshot) -> NSRect {
        let x = cursor.onWideTail ? max(0, cursor.x - 1) : cursor.x
        return cellRect(x: x, y: cursor.y, width: 2).insetBy(dx: -1, dy: -1)
    }

    // MARK: - 描画（design D6）

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let background = defaultBackground
        context.setFillColor(cgColor(background))

        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        let dirtyRects = (rects != nil && count > 0) ? Array(UnsafeBufferPointer(start: rects, count: count)) : [dirtyRect]

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for rect in dirtyRects {
            context.setFillColor(cgColor(background))
            context.fill(rect)
            drawCells(in: rect, context: context)
        }
        drawCursor(dirtyRects: dirtyRects, context: context)
        drawMarkedText(dirtyRects: dirtyRects, context: context)
    }

    var defaultForeground: ColorRGB { frameColors?.foreground ?? palette.foreground }
    var defaultBackground: ColorRGB { frameColors?.background ?? palette.background }

    private func drawCells(in dirtyRect: NSRect, context: CGContext) {
        // 描画の範囲がビューより大きく渡されることがある（オフスクリーンの描画など）。行・列に直す前に bounds に収める。
        let rect = dirtyRect.intersection(bounds)
        guard rows > 0, cols > 0, !rect.isNull, !rect.isEmpty else { return }
        let firstRow = max(0, Int(((rect.minY - padding) / metrics.height).rounded(.down)))
        let lastRow = min(rows - 1, Int(((rect.maxY - padding) / metrics.height).rounded(.up)))
        // 2 セル幅の文字が範囲の手前から始まることがあるので、1 セル広げる。
        let firstCol = max(0, Int(((rect.minX - padding) / metrics.width).rounded(.down)) - 1)
        let lastCol = min(cols - 1, Int(((rect.maxX - padding) / metrics.width).rounded(.up)))
        guard firstRow <= lastRow, firstCol <= lastCol else { return }

        context.saveGState()
        context.clip(to: rect)
        for y in firstRow...lastRow {
            drawRow(y, columns: firstCol...lastCol, context: context)
        }
        context.restoreGState()
    }

    /// セルの色（反転・太字の明るい色・コントラスト補正を反映したもの）。
    private struct ResolvedColors {
        var foreground: ColorRGB
        var background: ColorRGB
    }

    private func resolveColors(_ cell: CellSnapshot) -> ResolvedColors {
        var foreground = cell.foreground ?? defaultForeground
        // xterm.js の既定（drawBoldTextInBrightColors）と同じく、太字の ANSI 0〜7 は明るい色で描く。
        if cell.attributes.contains(.bold), let index = cell.foregroundPaletteIndex, index < 8 {
            let palette = frameColors?.palette ?? self.palette.colors
            if palette.count > Int(index) + 8 { foreground = palette[Int(index) + 8] }
        }
        var background = cell.background ?? defaultBackground
        if cell.attributes.contains(.inverse) {
            swap(&foreground, &background)
        }
        return ResolvedColors(foreground: contrastAdjusted(foreground, on: background), background: background)
    }

    private func contrastAdjusted(_ foreground: ColorRGB, on background: ColorRGB) -> ColorRGB {
        let key = ColorPair(foreground: foreground, background: background)
        if let cached = contrastCache[key] { return cached }
        let adjusted = ContrastAdjuster.adjust(foreground: foreground, background: background)
        contrastCache[key] = adjusted
        return adjusted
    }

    private func drawRow(_ y: Int, columns: ClosedRange<Int>, context: CGContext) {
        let row = cells[y]
        let resolved = columns.map { resolveColors(row[$0]) }
        let rowTop = padding + CGFloat(y) * metrics.height

        // 1. 同じ背景色が続く区間ごとに塗る。
        var start = columns.lowerBound
        while start <= columns.upperBound {
            let color = resolved[start - columns.lowerBound].background
            var end = start
            while end + 1 <= columns.upperBound, resolved[end + 1 - columns.lowerBound].background == color {
                end += 1
            }
            if color != defaultBackground {
                context.setFillColor(cgColor(color))
                context.fill(NSRect(
                    x: padding + CGFloat(start) * metrics.width, y: rowTop,
                    width: CGFloat(end - start + 1) * metrics.width, height: metrics.height
                ))
            }
            start = end + 1
        }

        // 選択範囲は配色の選択色で塗る（文字の色はそのまま）。
        if y < rowSelections.count, let selected = rowSelections[y], selected.overlaps(columns) {
            let lower = max(selected.lowerBound, columns.lowerBound)
            let upper = min(selected.upperBound, columns.upperBound)
            context.setFillColor(cgColor(palette.selection))
            context.fill(NSRect(
                x: padding + CGFloat(lower) * metrics.width, y: rowTop,
                width: CGFloat(upper - lower + 1) * metrics.width, height: metrics.height
            ))
        }

        // 2. 同じスタイルが続く区間ごとにグリフを描く。
        var run: [Int] = []
        var runKey: TextRunKey?
        func flush() {
            if let runKey, !run.isEmpty {
                drawText(run.map { row[$0] }, columns: run, key: runKey, rowTop: rowTop, context: context)
            }
            run.removeAll(keepingCapacity: true)
        }
        for x in columns {
            let cell = row[x]
            guard cell.width != .spacerTail, cell.width != .spacerHead, !cell.text.isEmpty,
                  !cell.attributes.contains(.invisible) else {
                flush()
                runKey = nil
                continue
            }
            let key = TextRunKey(
                font: fonts.fontForText(cell.text, bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic)),
                color: resolved[x - columns.lowerBound].foreground,
                faint: cell.attributes.contains(.faint)
            )
            if key != runKey {
                flush()
                runKey = key
            }
            run.append(x)
        }
        flush()

        // 3. 下線・打ち消し線・上線。
        drawDecorations(row, columns: columns, resolved: resolved, rowTop: rowTop, context: context)
    }

    struct TextRunKey: Equatable {
        let font: CTFont
        let color: ColorRGB
        let faint: Bool

        static func == (lhs: TextRunKey, rhs: TextRunKey) -> Bool {
            lhs.font == rhs.font && lhs.color == rhs.color && lhs.faint == rhs.faint
        }
    }

    /// 1 つのスタイルの区間を描く。グリフは、そのグリフの元の文字があるセルの位置に置く（グリッドからずれない）。
    func drawText(
        _ runCells: [CellSnapshot],
        columns: [Int],
        key: TextRunKey,
        rowTop: CGFloat,
        context: CGContext,
        colorOverride: ColorRGB? = nil
    ) {
        var text = ""
        var columnForUTF16: [Int] = []
        for (cell, column) in zip(runCells, columns) {
            text += cell.text
            columnForUTF16.append(contentsOf: repeatElement(column, count: cell.text.utf16.count))
        }
        guard !text.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): key.font,
            NSAttributedString.Key(kCTLigatureAttributeName as String): 0,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let color = colorOverride ?? key.color
        context.setFillColor(cgColor(color, alpha: key.faint ? 0.5 : 1))
        let baseline = rowTop + metrics.baselineOffset

        for glyphRun in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(glyphRun)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(glyphRun, range, &glyphs)
            CTRunGetPositions(glyphRun, range, &positions)
            CTRunGetStringIndices(glyphRun, range, &indices)
            let runAttributes = CTRunGetAttributes(glyphRun) as NSDictionary
            let runFont = runAttributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? key.font

            // セルの中での相対位置（結合文字など）は保ち、セルの先頭はグリッドに合わせる。
            //
            // CTFontDrawGlyphs の位置はテキスト空間の座標で、テキスト行列（上下を反転している。`draw(_:)`）を通して
            // ビューの座標になる。ビューの y（下向き）を渡すとビューの外（上）に描かれてしまうので、y の符号を反転して渡す。
            var cellOrigin: [Int: CGFloat] = [:]
            var placed = [CGPoint](repeating: .zero, count: count)
            for index in 0..<count {
                let utf16Index = min(max(0, indices[index]), columnForUTF16.count - 1)
                let column = columnForUTF16[utf16Index]
                let origin = cellOrigin[column] ?? positions[index].x
                cellOrigin[column] = origin
                let viewY = baseline - positions[index].y
                placed[index] = CGPoint(
                    x: padding + CGFloat(column) * metrics.width + (positions[index].x - origin),
                    y: -viewY
                )
            }
            CTFontDrawGlyphs(runFont, glyphs, placed, count, context)
        }
    }

    private func drawDecorations(
        _ row: [CellSnapshot],
        columns: ClosedRange<Int>,
        resolved: [ResolvedColors],
        rowTop: CGFloat,
        context: CGContext
    ) {
        let font = fonts.regular as CTFont
        let thickness = max(1 / metrics.scale, CTFontGetUnderlineThickness(font).rounded(.toNearestOrAwayFromZero, scale: metrics.scale))
        let baseline = rowTop + metrics.baselineOffset
        let underlineY = min(rowTop + metrics.height - thickness, baseline - CTFontGetUnderlinePosition(font) + thickness / 2)
        let strikeY = (baseline - CTFontGetXHeight(font) / 2).rounded(.toNearestOrAwayFromZero, scale: metrics.scale)

        for x in columns {
            let cell = row[x]
            guard cell.width != .spacerTail, !cell.attributes.contains(.invisible) else { continue }
            let hasLine = cell.underline != .none || cell.attributes.contains(.strikethrough) || cell.attributes.contains(.overline)
            guard hasLine else { continue }
            let span = cell.width == .wide ? 2 : 1
            let left = padding + CGFloat(x) * metrics.width
            let width = CGFloat(span) * metrics.width
            let colors = resolved[x - columns.lowerBound]
            let alpha: CGFloat = cell.attributes.contains(.faint) ? 0.5 : 1

            if cell.underline != .none {
                let color = cell.underlineColor ?? colors.foreground
                drawUnderline(cell.underline, x: left, width: width, y: underlineY, thickness: thickness,
                              color: cgColor(color, alpha: alpha), context: context)
            }
            context.setFillColor(cgColor(colors.foreground, alpha: alpha))
            if cell.attributes.contains(.strikethrough) {
                context.fill(NSRect(x: left, y: strikeY - thickness / 2, width: width, height: thickness))
            }
            if cell.attributes.contains(.overline) {
                context.fill(NSRect(x: left, y: rowTop, width: width, height: thickness))
            }
        }
    }

    private func drawUnderline(
        _ style: UnderlineStyle,
        x: CGFloat,
        width: CGFloat,
        y: CGFloat,
        thickness: CGFloat,
        color: CGColor,
        context: CGContext
    ) {
        context.setFillColor(color)
        context.setStrokeColor(color)
        switch style {
        case .none:
            return
        case .single:
            context.fill(NSRect(x: x, y: y, width: width, height: thickness))
        case .double:
            context.fill(NSRect(x: x, y: y - thickness, width: width, height: thickness))
            context.fill(NSRect(x: x, y: y + thickness, width: width, height: thickness))
        case .curly:
            let amplitude = max(thickness, metrics.height * 0.06)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: y))
            let step = metrics.width / 2
            var position = x
            var up = true
            while position < x + width {
                let next = min(position + step, x + width)
                path.addQuadCurve(
                    to: CGPoint(x: next, y: y),
                    control: CGPoint(x: (position + next) / 2, y: y + (up ? -amplitude : amplitude))
                )
                position = next
                up.toggle()
            }
            context.setLineWidth(thickness)
            context.addPath(path)
            context.strokePath()
        case .dotted, .dashed:
            context.saveGState()
            context.setLineWidth(thickness)
            let dash: [CGFloat] = style == .dotted ? [thickness, thickness * 2] : [metrics.width * 0.4, metrics.width * 0.2]
            context.setLineDash(phase: 0, lengths: dash)
            context.move(to: CGPoint(x: x, y: y + thickness / 2))
            context.addLine(to: CGPoint(x: x + width, y: y + thickness / 2))
            context.strokePath()
            context.restoreGState()
        }
    }

    // MARK: - カーソル（spec: terminal-rendering「Cursor」）

    private func drawCursor(dirtyRects: [NSRect], context: CGContext) {
        guard let cursor, cursor.visible, cursor.y >= 0, cursor.y < rows, cursor.x >= 0, cursor.x < cols else { return }
        let focused = hasKeyboardFocus
        // フォーカス中だけ点滅する。フォーカスが無いときは点滅しない中抜きのブロック。
        if focused && cursor.blinking && !blinkVisible { return }

        let x = cursor.onWideTail ? max(0, cursor.x - 1) : cursor.x
        let cell = cells[cursor.y][x]
        let span = cell.width == .wide ? 2 : 1
        let rect = cellRect(x: x, y: cursor.y, width: span)
        guard dirtyRects.contains(where: { $0.intersects(rect) }) else { return }

        let color = frameColors?.cursor ?? palette.cursor
        let shape = focused ? cursor.shape : .hollowBlock
        let line = max(1 / metrics.scale, (1 as CGFloat).rounded(.toNearestOrAwayFromZero, scale: metrics.scale))

        context.saveGState()
        context.clip(to: rect)
        switch shape {
        case .block:
            context.setFillColor(cgColor(color))
            context.fill(rect)
            // カーソルの下の文字は、セルの背景色で描く。
            if !cell.text.isEmpty, !cell.attributes.contains(.invisible) {
                let key = TextRunKey(
                    font: fonts.fontForText(cell.text, bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic)),
                    color: resolveColors(cell).background,
                    faint: false
                )
                drawText([cell], columns: [x], key: key, rowTop: rect.minY, context: context)
            }
        case .underline:
            context.setFillColor(cgColor(color))
            context.fill(NSRect(x: rect.minX, y: rect.maxY - 2 * line, width: rect.width, height: 2 * line))
        case .bar:
            context.setFillColor(cgColor(color))
            context.fill(NSRect(x: rect.minX, y: rect.minY, width: 2 * line, height: rect.height))
        case .hollowBlock:
            context.setStrokeColor(cgColor(color))
            context.setLineWidth(line)
            context.stroke(rect.insetBy(dx: line / 2, dy: line / 2))
        }
        context.restoreGState()
    }

    /// - Parameter isFirstResponder: first responder が変わる途中なら、その結果。nil なら今の状態を読む
    private func focusDidChange(isFirstResponder: Bool? = nil) {
        if let cursor { setNeedsDisplay(cursorRect(cursor)) }
        restartBlink()
        let focused = window?.isKeyWindow == true && (isFirstResponder ?? (window?.firstResponder === self))
        if focused {
            onFocus?()
        }
        // DECSET 1004 を有効にしているプログラムに、フォーカスの変化を報告する（spec: terminal-input）。
        if reportedFocus != focused {
            reportedFocus = focused
            controller?.enqueueFocus(focused)
        }
    }

    /// 点滅を表示の状態からやり直す（キー入力やカーソルの移動のあと）。
    func restartBlink() {
        blinkVisible = true
        let shouldBlink = hasKeyboardFocus && (cursor?.blinking ?? false) && (cursor?.visible ?? false)
        guard shouldBlink else {
            stopBlinking()
            return
        }
        blinkTimer?.invalidate()
        let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleBlink() }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkVisible = true
    }

    private func toggleBlink() {
        blinkVisible.toggle()
        // カーソルのセルだけを再描画する。
        if let cursor { setNeedsDisplay(cursorRect(cursor)) }
    }

    // MARK: - 色

    private struct RGBAKey: Hashable {
        let color: ColorRGB
        let alpha: CGFloat
    }

    private struct ColorPair: Hashable {
        let foreground: ColorRGB
        let background: ColorRGB
    }

    func cgColor(_ color: ColorRGB, alpha: CGFloat = 1) -> CGColor {
        let key = RGBAKey(color: color, alpha: alpha)
        if let cached = colorCache[key] { return cached }
        let value = CGColor(
            srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: alpha
        )
        colorCache[key] = value
        return value
    }
}

extension KeyInput.Modifiers {
    /// `NSEvent.modifierFlags` から作る。
    public init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.capsLock) { insert(.capsLock) }
    }
}

extension KeyStroke {
    /// `NSEvent`（keyDown / keyUp）から作る。
    public init(event: NSEvent, phase: Phase, isComposing: Bool) {
        let isKey = event.type == .keyDown || event.type == .keyUp
        self.init(
            phase: phase,
            keyCode: event.keyCode,
            characters: isKey ? event.characters : "",
            charactersIgnoringModifiers: isKey ? event.charactersIgnoringModifiers : "",
            modifiers: KeyInput.Modifiers(event.modifierFlags),
            isComposing: isComposing
        )
    }
}

extension KeyInput {
    /// `NSEvent`（keyDown / keyUp）から作る。
    /// - Parameter text: キーが作った文字（`insertText` で届いたもの）。nil なら `NSEvent.characters`
    public init?(event: NSEvent, text: String? = nil) {
        let action: Action
        switch event.type {
        case .keyDown: action = event.isARepeat ? .repeat : .press
        case .keyUp: action = .release
        default: return nil
        }
        guard let input = KeyInput.mac(
            keyCode: event.keyCode,
            characters: text ?? event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            unshiftedCharacters: event.characters(byApplyingModifiers: []),
            modifiers: Modifiers(event.modifierFlags),
            action: action
        ) else {
            return nil
        }
        self = input
    }
}
