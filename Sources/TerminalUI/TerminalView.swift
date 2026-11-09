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
            // 表示しているセッションに変化があったら、止めていた display link を再開する（phase5 design D3）。
            oldValue?.setRenderObserver(nil)
            controller?.setRenderObserver { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.wakeDisplayLink() }
                }
            }
            resetModel()
            resetInputState()
            searchSessionDidChange(from: oldValue)
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

    // 描画のモデル（最後に受け取ったスナップショットの内容）。描画の実装（`TerminalRenderer`）が読む。
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var cells: [[CellSnapshot]] = []
    /// 行ごとの選択されている列の範囲。
    private(set) var rowSelections: [ClosedRange<Int>?] = []
    private(set) var frameColors: FrameColors?
    private(set) var cursor: CursorSnapshot?
    /// viewport の行ごとの検索の一致（`TerminalView+Find.swift`）。
    private(set) var searchHighlights: [Int: [SearchHighlight]] = [:]
    /// viewport の中の画像の配置（Kitty Graphics。層、z の順）。
    private(set) var images: [ImagePlacement] = []
    /// 中身をもう一度もらいに行った画像の世代（もらえなかったときに、何度も頼まない）。
    private var requestedImageGenerations: Set<UInt64> = []
    /// 検索バー（最初に開くときにビューに入れる）。
    let findBar = FindBarView()
    /// 検索を頼むたびに増える（遅れて返ってきた古い結果を捨てる）。
    var searchSequence = 0
    /// 行ごとの、次の行にソフト折り返しで続くか（素の URL を行をまたいで探す）。
    private(set) var rowWrapped: [Bool] = []
    /// Command を押している間、ポインタの下にあるリンク（`TerminalView+Links.swift`）。
    var hoveredLink: TerminalLink?
    /// 最後にリンクを探したセル。
    var lastLinkCell: GridPoint?
    /// リンクを探すたびに増える（遅れて返ってきた古い結果を捨てる）。
    var linkLookupSequence = 0
    /// リンクを開く（テストで差し替える）。
    public var linkOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Command を押しているか（テストで差し替える）。
    var commandKeyIsDown: () -> Bool = { NSEvent.modifierFlags.contains(.command) }

    /// 描画の実装（spec: terminal-rendering「Rendering parity」、phase5 design D1）。
    private(set) var renderer: any TerminalRenderer
    /// 求められた描画の実装（`TABGHOSTTY_RENDERER`）。Metal は、シェーダーのコンパイルが終わるまで Core Text で描く。
    public let requestedRenderer: TerminalRendererKind
    /// 今使っている描画の実装。
    public var activeRenderer: TerminalRendererKind { renderer.kind }

    // IME（`TerminalView+TextInput.swift`）
    /// 未確定の文字列。空なら変換していない。
    var markedText = ""
    /// 未確定の文字列の中で選ばれている範囲（UTF-16）。
    var markedSelectedRange = NSRange(location: 0, length: 0)
    /// `.interpret` のキーを `interpretKeyEvents` に渡している間に、`insertText` で届いた文字列。それ以外のときは nil。
    var insertedTexts: [String]?
    /// `.interpret` のキーを渡している間に、未確定の文字列が変わった。
    var markedTextChangedDuringInterpret = false
    /// 変換中のキーを IME に渡している最中。
    var isInterpretingForInputMethod = false
    /// 変換中のキーを IME に渡している間に、IME がキーをコマンドとして返した（`doCommand(by:)`）。
    var inputMethodPassedCommand = false
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
    /// display link を止める・再開する判断（phase5 design D3）。
    private(set) var pacer = FramePacer()
    /// 入力遅延の計測（`TABGHOSTTY_LATENCY_LOG=1` のときだけ。phase5 tasks 3.2）。
    var latencyProbe = InputLatencyProbe.makeIfEnabled()

    private var blinkTimer: Timer?
    private(set) var blinkVisible = true
    /// 点滅の切り替えで再描画を頼んでいる最中（`wakeDisplayLink` がアイドルの時計を進めないように）。
    private var isBlinkInvalidation = false
    private var resizeTask: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []

    private var contrastCache: [ColorPair: ColorRGB] = [:]
    /// コントラストのキャッシュの数（テスト用）。
    var contrastCacheCount: Int { contrastCache.count }

    /// カーソルの点滅間隔（SPEC: 約 530 ms）。
    static let blinkInterval: TimeInterval = 0.53

    /// - Parameter renderer: 描画の実装。既定は環境変数 `TABGHOSTTY_RENDERER`（未設定なら Metal）
    public convenience init(
        fontFamily: String,
        fontSize: CGFloat,
        palette: Palette,
        renderer requested: TerminalRendererKind = .fromEnvironment()
    ) {
        self.init(fontFamily: fontFamily, fontSize: fontSize, palette: palette, renderer: requested,
                  metalContext: MetalRenderContextLoader.request)
    }

    /// Metal の描画に使うものを、作り終わったら（作れなければ nil で）渡す。
    typealias MetalContextProvider = @MainActor (@escaping @MainActor (MetalRenderContext?) -> Void) -> Void

    /// - Parameter metalContext: Metal の描画に使うものを渡す（テストで差し替える）
    init(
        fontFamily: String,
        fontSize: CGFloat,
        palette: Palette,
        renderer requested: TerminalRendererKind,
        metalContext: MetalContextProvider
    ) {
        self.fontFamily = fontFamily
        fonts = FontResolver(fontFamily: fontFamily, size: fontSize)
        self.palette = palette
        metrics = CellMetrics.make(font: fonts.regular, scale: NSScreen.main?.backingScaleFactor ?? 2)
        requestedRenderer = requested
        // シェーダーのコンパイルが終わるまでは Core Text で描く（phase5 design D1 の Risks）。
        renderer = CoreTextRenderer()
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        renderer.onNeedsFrame = { [weak self] in self?.wakeDisplayLink() }
        renderer.install(in: self)
        setUpImageDrop()
        if requested == .metal {
            metalContext { [weak self] context in
                // 作れなかったら Core Text で描き続ける（ログは `MetalRenderContextLoader` が出す）。
                guard let self, let context, self.renderer.kind != .metal else { return }
                self.replaceRenderer(with: MetalRenderer(context: context))
            }
        }
    }

    /// Metal のシェーダーのコンパイルを始めておく（`TABGHOSTTY_RENDERER` が Metal のとき）。
    /// アプリの起動時に呼ぶと、最初のビューを作るまでに終わっていることが多い。
    public static func preloadRenderer(_ kind: TerminalRendererKind = .fromEnvironment()) {
        guard kind == .metal else { return }
        MetalRenderContextLoader.preload()
    }

    /// 描画の実装を差し替え、全体を描き直す。
    func replaceRenderer(with next: any TerminalRenderer) {
        renderer.uninstall()
        renderer.onNeedsFrame = nil
        renderer = next
        next.onNeedsFrame = { [weak self] in self?.wakeDisplayLink() }
        next.install(in: self)
        next.invalidateAll()
        // 新しい実装は画像の中身を持っていないので、もらい直す。
        requestedImageGenerations.removeAll()
        if !images.isEmpty {
            needsFullSnapshot = true
            wakeDisplayLink()
        }
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
        // 最小化したとき・ほかのウィンドウに完全に隠れたときは描かない（点滅も止める。phase5 design D3）。
        windowObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionDidChange() }
        })
        // vsync に合わせて tick する（spec: terminal-rendering「Idle efficiency」）。
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        pacer = FramePacer()
        updateMetrics()
        scheduleGridUpdate()
        focusDidChange()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Retina と外部モニタの間を移ったら、セルの寸法とグリフを計算し直す（device pixel が変わる）。
        updateMetrics()
        scheduleGridUpdate()
        renderer.layoutChanged()
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
            isInterpretingForInputMethod = true
            inputMethodPassedCommand = false
            interpretKeyEvents([event])
            isInterpretingForInputMethod = false
            // IME が確定してから、そのキーをコマンドとして返した（韓国語の入力の Return や矢印、Option-E の後の Return など）。
            // 変換が終わっていれば、確定した文字列（insertText で送った）の後に、そのキーを送る。
            if inputMethodPassedCommand, !hasMarkedText(), let input = KeyInput(event: event) {
                latencyProbe?.keyDown()
                controller?.enqueueKey(input)
            }
        case .send(let text):
            latencyProbe?.keyDown()
            controller?.enqueueText(text)
        case .encode:
            latencyProbe?.keyDown()
            if let input = KeyInput(event: event) {
                controller?.enqueueKey(input)
            }
        case .interpret:
            latencyProbe?.keyDown()
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
        // Command を押した・離した: ポインタの下のリンクの下線を出す・消す（spec: terminal-links）。
        if let window {
            updateLinkHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: event.modifierFlags)
        }
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
        renderer.invalidateAll()
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
        renderer.layoutChanged()
        scheduleGridUpdate()
    }

    // MARK: - グリッドのサイズ（spec: terminal-rendering「Grid size follows the view」）

    private func updateMetrics() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let next = CellMetrics.make(font: fonts.regular, scale: scale)
        guard next != metrics else { return }
        metrics = next
        renderer.layoutChanged()
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
        // カーソルの点滅など、スナップショットに依らない変化を描く（Metal。Core Text は AppKit が描く）。
        renderFrame()
        requestSnapshotIfNeeded()
        // 描くものが無い tick が続いたら止める。出力・入力・点滅で `wakeDisplayLink` が再開する。
        let busy = renderer.needsFrame || snapshotInFlight || needsFullSnapshot || (controller?.needsRender ?? false)
        if pacer.tick(busy: busy) {
            link.isPaused = true
        }
    }

    /// display link で描く実装（Metal）なら、変化があれば描く。
    private func renderFrame() {
        if renderer.renderFrameIfNeeded() {
            latencyProbe?.framePresented()
        }
    }

    /// 描くものができた。止めていた display link を再開する（ウィンドウが見えていなければ止めたまま）。
    func wakeDisplayLink() {
        // 点滅だけの変化は、描くために再開するが、アイドルの時計は進めない（点滅の合間は止めておく。phase5 design D3）。
        if pacer.activity(countsAsActivity: !isBlinkInvalidation) {
            displayLink?.isPaused = false
        }
    }

    /// display link が止まっているか（テスト用）。
    var isDisplayLinkPaused: Bool { displayLink?.isPaused ?? true }

    /// ウィンドウが見えるようになった / 見えなくなった。
    func occlusionDidChange() {
        setWindowVisible(window?.occlusionState.contains(.visible) ?? false)
    }

    func setWindowVisible(_ visible: Bool) {
        guard visible != pacer.isVisible else { return }
        let resume = pacer.setVisible(visible)
        displayLink?.isPaused = !resume
        if visible {
            // 隠れている間の変化をまとめて描く。
            renderer.invalidateAll()
            restartBlink()
        } else {
            stopBlinking()
        }
    }

    /// 端末に変化があれば、スナップショットを取りに行く（1 フレームにつき高々 1 回）。
    private func requestSnapshotIfNeeded() {
        guard let controller, !snapshotInFlight else { return }
        guard needsFullSnapshot || controller.needsRender else { return }
        snapshotInFlight = true
        let full = needsFullSnapshot
        needsFullSnapshot = false
        let known = renderer.knownImageGenerations
        Task { [weak self] in
            let snapshot = await controller.makeSnapshot(forceFull: full, knownImageGenerations: known)
            guard let self else { return }
            self.snapshotInFlight = false
            guard self.controller === controller else { return }
            guard let snapshot else {
                // 取れなかった（同期出力の保留中など）。全体を求めていたなら、次も全体を求める。
                if full { self.needsFullSnapshot = true }
                return
            }
            self.apply(snapshot)
            // 同じ vsync の間に描く（次の tick を待たない）。
            self.renderFrame()
        }
    }

    private func resetModel() {
        cols = 0
        rows = 0
        cells = []
        rowSelections = []
        rowWrapped = []
        hoveredLink = nil
        if !images.isEmpty {
            images = []
            renderer.updateImages([], pixels: [:])
        }
        requestedImageGenerations.removeAll()
        cursor = nil
        frameColors = nil
        searchHighlights = [:]
        needsFullSnapshot = true
        renderer.invalidateAll()
        wakeDisplayLink()
    }

    /// スナップショットをモデルに反映し、変わったところだけ再描画を頼む。
    func apply(_ snapshot: FrameSnapshot) {
        var redrawAll = snapshot.isFull
        if snapshot.cols != cols || snapshot.rows != rows {
            cols = snapshot.cols
            rows = snapshot.rows
            cells = Array(repeating: Array(repeating: .blank, count: cols), count: rows)
            rowSelections = Array(repeating: nil, count: rows)
            rowWrapped = Array(repeating: false, count: rows)
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
            rowWrapped[row.y] = snapshot.wrappedRows.contains(row.y)
            dirtyRows.insert(row.y)
        }

        if snapshot.searchHighlights != searchHighlights {
            // 強調が変わった行だけを描き直す（一致の行は、端末の内容が変わっていなくても変わる）。
            for y in Set(searchHighlights.keys).union(snapshot.searchHighlights.keys)
            where y >= 0 && y < rows && searchHighlights[y] != snapshot.searchHighlights[y] {
                dirtyRows.insert(y)
            }
            searchHighlights = snapshot.searchHighlights
        }

        applyImages(snapshot)

        let cursorChanged = snapshot.cursor != cursor
        if cursorChanged {
            if let old = cursor { renderer.invalidate(cursorRect(old)) }
            cursor = snapshot.cursor
            if let new = cursor { renderer.invalidate(cursorRect(new)) }
            restartBlink()
        }

        if redrawAll {
            renderer.invalidateAll()
        } else if !dirtyRows.isEmpty {
            renderer.invalidateRows(dirtyRows)
        }
        if redrawAll || !dirtyRows.isEmpty || cursorChanged {
            latencyProbe?.snapshotChanged()
        }
        linkRowsChanged(dirtyRows, all: redrawAll)
    }

    /// 画像の配置を反映する（spec: inline-images）。描画の実装が中身を持っていない画像があれば、もらい直す。
    private func applyImages(_ snapshot: FrameSnapshot) {
        if snapshot.images != images || !snapshot.imagePixels.isEmpty {
            let old = images
            images = snapshot.images
            renderer.updateImages(images, pixels: snapshot.imagePixels)
            for placement in old + images {
                renderer.invalidate(imageRect(placement))
            }
        }
        let missing = Set(images.map(\.generation)).subtracting(renderer.knownImageGenerations)
        if !missing.isEmpty, !missing.isSubset(of: requestedImageGenerations) {
            requestedImageGenerations.formUnion(missing)
            needsFullSnapshot = true
            wakeDisplayLink()
        }
    }

    /// 画像を描く矩形（ビューの座標）。画像の大きさは device pixel なので、画面の倍率で割る。
    func imageRect(_ placement: ImagePlacement) -> NSRect {
        let scale = metrics.scale
        return NSRect(
            x: padding + CGFloat(placement.column) * metrics.width + CGFloat(placement.offsetX) / scale,
            y: padding + CGFloat(placement.row) * metrics.height + CGFloat(placement.offsetY) / scale,
            width: CGFloat(placement.pixelWidth) / scale,
            height: CGFloat(placement.pixelHeight) / scale
        )
    }

    /// セルを描く範囲（画像はこの外に描かない）。
    var gridRect: NSRect {
        NSRect(x: padding, y: padding, width: CGFloat(gridColumns) * metrics.width, height: CGFloat(gridRows) * metrics.height)
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

    func cursorRect(_ cursor: CursorSnapshot) -> NSRect {
        let x = cursor.onWideTail ? max(0, cursor.x - 1) : cursor.x
        return cellRect(x: x, y: cursor.y, width: 2).insetBy(dx: -1, dy: -1)
    }

    // MARK: - 描画（phase5 design D1）

    public override func draw(_ dirtyRect: NSRect) {
        // Core Text で描くときだけ、ビューのレイヤーに描く（Metal はサブビューの CAMetalLayer に描く）。
        guard let coreText = renderer as? CoreTextRenderer, let context = NSGraphicsContext.current?.cgContext else { return }
        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        let dirtyRects = (rects != nil && count > 0) ? Array(UnsafeBufferPointer(start: rects, count: count)) : [dirtyRect]
        coreText.draw(dirtyRects: dirtyRects, in: context)
        latencyProbe?.framePresented()
    }

    var defaultForeground: ColorRGB { frameColors?.foreground ?? palette.foreground }
    var defaultBackground: ColorRGB { frameColors?.background ?? palette.background }
    /// カーソルの色（プログラムが OSC 12 で変えた色、無ければ配色の色）。
    var cursorColor: ColorRGB { frameColors?.cursor ?? palette.cursor }

    /// セルの色（反転・太字の明るい色・コントラスト補正を反映したもの）。
    struct ResolvedColors: Equatable {
        var foreground: ColorRGB
        var background: ColorRGB
    }

    func resolveColors(_ cell: CellSnapshot) -> ResolvedColors {
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

    func contrastAdjusted(_ foreground: ColorRGB, on background: ColorRGB) -> ColorRGB {
        let key = ColorPair(foreground: foreground, background: background)
        if let cached = contrastCache[key] { return cached }
        let adjusted = ContrastAdjuster.adjust(foreground: foreground, background: background)
        // truecolor の動画などでは組み合わせが際限なく増えるので、上限を超えたら捨てて作り直す。
        if contrastCache.count >= Self.colorCacheLimit {
            contrastCache.removeAll(keepingCapacity: true)
        }
        contrastCache[key] = adjusted
        return adjusted
    }

    /// 色のキャッシュ（コントラストの調整、Core Text の CGColor）に置く数の上限。
    static let colorCacheLimit = 4096

    /// カーソルを描くセル（2 セル幅の文字の 2 セル目にいれば 1 セル目）と幅。描かないときは nil。
    ///
    /// フォーカス中だけ点滅し、消灯中は nil。フォーカスが無いときは点滅しない中抜きのブロック。
    var visibleCursor: (x: Int, y: Int, span: Int, shape: CursorShape)? {
        guard let cursor, cursor.visible, cursor.y >= 0, cursor.y < rows, cursor.x >= 0, cursor.x < cols else { return nil }
        let focused = hasKeyboardFocus
        if focused && cursor.blinking && !blinkVisible { return nil }
        let x = cursor.onWideTail ? max(0, cursor.x - 1) : cursor.x
        let span = cells[cursor.y][x].width == .wide ? 2 : 1
        return (x, cursor.y, span, focused ? cursor.shape : .hollowBlock)
    }

    /// - Parameter isFirstResponder: first responder が変わる途中なら、その結果。nil なら今の状態を読む
    private func focusDidChange(isFirstResponder: Bool? = nil) {
        if let cursor { renderer.invalidate(cursorRect(cursor)) }
        let focused = window?.isKeyWindow == true && (isFirstResponder ?? (window?.firstResponder === self))
        // first responder が変わる途中は `hasKeyboardFocus` がまだ古いので、変わった後の状態で決める。
        restartBlink(focused: focused)
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
    /// - Parameter focused: キーボードのフォーカスがあるか。nil なら今の状態を読む
    func restartBlink(focused: Bool? = nil) {
        blinkVisible = true
        // 点滅は点灯と消灯を切り替えるときだけ描く（約 530 ms に 1 回）。ウィンドウが見えていなければ点滅しない。
        let shouldBlink = pacer.isVisible && (focused ?? hasKeyboardFocus) && (cursor?.blinking ?? false) && (cursor?.visible ?? false)
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
        // カーソルのセルだけを再描画する。点滅だけの変化なので、display link のアイドルの時計は進めない。
        guard let cursor else { return }
        isBlinkInvalidation = true
        renderer.invalidate(cursorRect(cursor))
        isBlinkInvalidation = false
    }

    // MARK: - 色

    private struct ColorPair: Hashable {
        let foreground: ColorRGB
        let background: ColorRGB
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
