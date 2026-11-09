import Dispatch
import GhosttyVt
import os

/// `TerminalController` がデーモンへ送るフレーム。
public enum TerminalOutgoingFrame: Equatable, Sendable {
    case attach(sid: String)
    case input(sid: String, bytes: [UInt8])
    case resize(sid: String, cols: Int, rows: Int)
}

/// フレームの送り先（`WSConnection`）。
///
/// 呼び出し側（actor）の中で順序を保つため、送信は同期的にキューへ積むだけにする。
public protocol TerminalFrameSink: AnyObject, Sendable {
    /// 送信キューに積む。切断中なら積まずに false を返す（切断中の入力は捨てる。spec: terminal-input）。
    @discardableResult
    func enqueue(_ frame: TerminalOutgoingFrame) -> Bool
}

/// プログラムがクリップボードに書き込んだテキストの書き込み先（`NSPasteboard`）。
public protocol TerminalClipboard: AnyObject, Sendable {
    /// OSC 52 などで書き込まれたテキスト。live のときだけ呼ぶ（replay の中の書き込みは捨てる。phase2 design D6）。
    func write(_ text: String)
}

/// ペーストの結果。
public enum PasteResult: Sendable, Equatable {
    /// 送った。
    case sent
    /// 確認が要る（何も送っていない。phase2 design D4）。
    case needsConfirmation
    /// live でない、または送るものが無いので何もしなかった。
    case ignored
}

/// IME の未確定の文字列（ビューが表示するもの）。タブを切り替えても失われないよう、コントローラに預ける（phase3 design D1）。
public struct ComposingText: Equatable, Sendable {
    public var text: String
    /// 未確定の文字列の中で選ばれている範囲（UTF-16）。
    public var selectedLocation: Int
    public var selectedLength: Int

    public init(text: String, selectedLocation: Int, selectedLength: Int) {
        self.text = text
        self.selectedLocation = selectedLocation
        self.selectedLength = selectedLength
    }
}

/// セッション 1 つ分の端末。VT ハンドルへのアクセスはすべてこの actor を通す
/// （spec: terminal-engine「Serialized access per terminal」、design D1）。
///
/// attach / replay / live のライフサイクル（spec: terminal-session）と、effect の振り分け（design D2）、
/// 入力のまとめ送り（spec: terminal-input）を受け持つ。
///
/// キー・テキスト・マウス・スクロール・フォーカス・選択の操作は、メインスレッドから同期的に 1 つのバッファに積み、
/// 次の周回でまとめて処理する（順序を保つ。phase2）。
public actor TerminalController {
    public enum Phase: Sendable, Equatable {
        /// attach していない（起動直後・切断中）。
        case detached
        /// attach を送り、replay を受け取っている。端末の応答もキー入力も送らない。
        case replaying
        /// replay が終わった。output を書き込み、入力と端末の応答を送る。
        case live
    }

    /// グリッドのサイズ（セル数と、セルのピクセルサイズ）。
    public struct GridSize: Equatable, Sendable {
        public var cols: Int
        public var rows: Int
        public var cellWidthPx: Int
        public var cellHeightPx: Int

        public init(cols: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) {
            self.cols = cols
            self.rows = rows
            self.cellWidthPx = cellWidthPx
            self.cellHeightPx = cellHeightPx
        }
    }

    public nonisolated let sid: String
    private let terminal: VTTerminal
    private let sink: any TerminalFrameSink
    /// 既定の配色。配色を切り替えたら差し替え、attach のたびに設定し直す。
    private var colors: TerminalColorConfiguration?
    private let clipboard: (any TerminalClipboard)?

    public private(set) var phase: Phase = .detached
    /// ビューから受け取ったグリッドのサイズ。まだ受け取っていなければ nil（resize フレームを送らない）。
    public private(set) var viewGrid: GridSize?

    /// 入力のバッファ（メインスレッドから同期的に積む）。
    private nonisolated let inputBuffer = OSAllocatedUnfairLock(initialState: InputBuffer())
    /// 受信した replay / output（受信ループから同期的に積む。phase5 design D2）。
    private nonisolated let incoming = OSAllocatedUnfairLock(initialState: IncomingBuffer())
    /// attach し直すか、接続が切れるたびに増える（書き込みの途中で止める）。
    private var writeEpoch = 0
    /// 描画すべき変化があるか、同期出力で保留しているか（ビューの display link から同期的に読む）。
    private nonisolated let renderGate = OSAllocatedUnfairLock(initialState: RenderGate())
    /// 同期出力の保留を始めるたびに増える（古い保留のタイムアウトを無視する）。
    private var renderHoldGeneration = 0

    // 検索（spec: terminal-search、phase5 design D5）
    private var searchQuery = ""
    private var searchMatches: [SearchMatch] = []
    private var searchIndex: Int?
    /// 新しい出力のあとの再検索を予約している。
    private var researchScheduled = false
    /// 再検索の結果を知らせる（検索バーの `n / m`）。
    private nonisolated let searchObserver = OSAllocatedUnfairLock<(@Sendable (SearchStatus) -> Void)?>(initialState: nil)
    /// 新しい出力が来てから、再検索するまでの時間（その間の出力はまとめて 1 回で検索する）。
    public static let researchDelay: Duration = .milliseconds(200)
    /// 描画すべき変化が起きたときに呼ぶ（表示しているビューが、止めていた display link を再開する。phase5 design D3）。
    private nonisolated let renderObserver = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    /// 入力の振り分けに使うモード（ビューから同期的に読む）。端末に書き込むたびに更新する。
    private nonisolated let modesState = OSAllocatedUnfairLock(initialState: TerminalInputModes())
    /// 次のスナップショットを全行にするか。
    private var forceFullSnapshot = true
    /// 前のスナップショットが失敗した（失敗が続く間は、ログを 1 回だけ出す）。
    private var snapshotFailing = false
    private static let log = Logger(subsystem: "com.tabghostty.app", category: "terminal")
    /// ビューが預けた未確定の文字列（ビューからだけ使う。メインスレッドから同期的に読み書きする）。
    private nonisolated let savedComposition = OSAllocatedUnfairLock<ComposingText?>(initialState: nil)

    /// 入力 1 つ。積んだ順に処理する。
    enum InputItem: Sendable {
        case key(KeyInput)
        /// そのまま送るテキスト（Shift+Enter、¥、IME で確定した文字列）。
        case text(String)
        case mouse(MouseInput)
        case scroll(ScrollInput)
        case focus(Bool)
        case selection(SelectionInput)
    }

    private struct InputBuffer {
        var items: [InputItem] = []
        var flushScheduled = false
    }

    /// 受信した端末の出力 1 つ。
    enum Incoming: Sendable {
        case replay([UInt8], done: Bool)
        case output([UInt8])

        var count: Int {
            switch self {
            case .replay(let bytes, _), .output(let bytes): return bytes.count
            }
        }
    }

    private struct IncomingBuffer {
        var items: [Incoming] = []
        /// 書き込んでいない残りのバイト数。
        var pendingBytes = 0
        var draining = false
    }

    /// 1 回に書き込む最大の大きさ。書き込むたびに actor を手放し、入力の送信やリサイズを後回しにしない。
    public static let writeChunkSize = 64 * 1024

    /// 描画してよいか（spec: terminal-rendering「Synchronized output」、phase5 design D4）。
    struct RenderGate: Sendable {
        /// 描画すべき変化がある。
        var pending = true
        /// プログラムが同期出力（DECSET 2026）で更新を止めた時刻。止めていなければ nil。
        var heldSince: ContinuousClock.Instant?
        /// 止めたままにする最長の時間（libghostty にタイムアウトは無いので、Ghostty 本体と同じ 1 秒を持つ）。
        var holdTimeout: Duration = TerminalController.renderHoldTimeout

        /// 今、描画を保留しているか（止めていて、タイムアウトが過ぎていない）。
        func isHeld(at now: ContinuousClock.Instant) -> Bool {
            guard let heldSince else { return false }
            return now - heldSince < holdTimeout
        }
    }

    /// 同期出力の保留のタイムアウト。
    public static let renderHoldTimeout: Duration = .seconds(1)

    /// - Parameters:
    ///   - sid: セッション ID
    ///   - cols / rows: ビューのサイズが分かるまで使う初期サイズ
    ///   - maxScrollback: `scrollback_lines`
    ///   - colors: 既定の配色。nil なら libghostty の既定値
    ///   - sink: フレームの送り先
    ///   - clipboard: OSC 52 の書き込み先。nil なら書き込まない
    public init(
        sid: String,
        cols: Int = 80,
        rows: Int = 24,
        maxScrollback: Int,
        colors: TerminalColorConfiguration?,
        sink: any TerminalFrameSink,
        clipboard: (any TerminalClipboard)? = nil
    ) throws {
        self.sid = sid
        self.sink = sink
        self.colors = colors
        self.clipboard = clipboard
        terminal = try VTTerminal(cols: cols, rows: rows, maxScrollback: maxScrollback)
        if let colors {
            try terminal.setColors(colors)
        }
    }

    // MARK: - ライフサイクル（spec: terminal-session）

    /// 端末をリセットしてから `attach` を送り、replay を待つ。
    /// 切断中で送れなければ detached のままにする（再接続したときに attach し直す）。
    @discardableResult
    public func attach() -> Bool {
        _ = drainInput()
        // 積んである出力は attach より前のもので、replay に含まれる。書き込みの途中なら、そこで止める。
        discardIncoming()
        writeEpoch += 1
        terminal.reset()
        if let colors {
            try? terminal.setColors(colors)
        }
        if !searchQuery.isEmpty {
            // 画面が空になったので、一致も無くなる（replay を受け取ったら、出力として検索し直す）。
            searchMatches = []
            searchIndex = nil
            publishSearchStatus()
        }
        _ = terminal.takeEffects()
        refreshInputModes()
        updateRenderHold()
        forceFullSnapshot = true
        markRenderPending()

        guard sink.enqueue(.attach(sid: sid)) else {
            phase = .detached
            return false
        }
        phase = .replaying
        return true
    }

    // MARK: - 受信した出力（phase5 design D2）

    /// `replay` フレームを積む。受信ループは書き込みを待たずに次のフレームを読む（ほかのセッションの出力を待たせない）。
    /// 積んだ順に、この actor の上で書き込む。
    public nonisolated func enqueueReplay(_ bytes: [UInt8], done: Bool) {
        enqueueIncoming(.replay(bytes, done: done))
    }

    /// `output` フレームを積む（`enqueueReplay` と同じ）。
    public nonisolated func enqueueOutput(_ bytes: [UInt8]) {
        enqueueIncoming(.output(bytes))
    }

    /// 積んだまま、まだ書き込んでいない出力のバイト数。
    public nonisolated var pendingOutputBytes: Int {
        incoming.withLock { $0.pendingBytes }
    }

    /// 積んだ出力をすべて書き込むまで待つ（テスト用）。
    public func waitUntilIncomingIsWritten() async {
        while incoming.withLock({ $0.draining || !$0.items.isEmpty }) {
            await Task.yield()
        }
    }

    private nonisolated func enqueueIncoming(_ item: Incoming) {
        let start = incoming.withLock { buffer -> Bool in
            buffer.items.append(item)
            buffer.pendingBytes += item.count
            guard !buffer.draining else { return false }
            buffer.draining = true
            return true
        }
        guard start else { return }
        Task { await self.drainIncoming() }
    }

    /// 積んである出力を、積んだ順に書き込む。
    ///
    /// フレームの間でも actor を手放す（デーモンは 32 KiB ほどのフレームで送るので、フレームの中で区切るだけでは
    /// 大量の出力の間ずっと actor を握ってしまう）。
    private func drainIncoming() async {
        while true {
            let next = incoming.withLock { buffer -> Incoming? in
                guard !buffer.items.isEmpty else {
                    buffer.draining = false
                    return nil
                }
                return buffer.items.removeFirst()
            }
            guard let next else { return }
            switch next {
            case .replay(let bytes, let done):
                await receiveReplay(bytes, done: done, countedAsPending: true)
            case .output(let bytes):
                await receiveOutput(bytes, countedAsPending: true)
            }
            await Task.yield()
        }
    }

    private func discardIncoming() {
        incoming.withLock { buffer in
            buffer.items.removeAll()
            buffer.pendingBytes = 0
        }
    }

    /// `replay` フレームを書き込む。`done` なら live に移り、ビューのグリッドサイズで `resize` を送る。
    public func receiveReplay(_ bytes: [UInt8], done: Bool) async {
        await receiveReplay(bytes, done: done, countedAsPending: false)
    }

    private func receiveReplay(_ bytes: [UInt8], done: Bool, countedAsPending: Bool) async {
        guard phase == .replaying else {
            if countedAsPending { consumePending(bytes.count) }
            return
        }
        guard await write(bytes, countedAsPending: countedAsPending) else { return }
        if done {
            phase = .live
            sendViewSize()
        }
    }

    /// `output` フレームを書き込む。
    ///
    /// live のときだけ書き込む。replay 中に届く output は、attach より前にデーモンが送り出したもので、
    /// replay の内容（リングバッファ）に含まれているので捨てる（overflow で attach し直したときに内容が重複しない）。
    public func receiveOutput(_ bytes: [UInt8]) async {
        await receiveOutput(bytes, countedAsPending: false)
    }

    private func receiveOutput(_ bytes: [UInt8], countedAsPending: Bool) async {
        guard phase == .live else {
            if countedAsPending { consumePending(bytes.count) }
            return
        }
        _ = await write(bytes, countedAsPending: countedAsPending)
    }

    /// 端末に書き込む。最大 `writeChunkSize` ずつ書き込み、そのたびに actor を手放す（`Task.yield()`）。
    /// その間に積まれた入力の送信・リサイズ・スナップショットの作成が先に進む（spec: terminal-rendering
    /// 「Responsiveness under heavy output」）。
    /// - Returns: 最後まで書き込んだら true。途中で attach し直したか、接続が切れたら false（残りは捨てる）
    private func write(_ bytes: [UInt8], countedAsPending: Bool) async -> Bool {
        let epoch = writeEpoch
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + Self.writeChunkSize, bytes.count)
            terminal.write(bytes[offset..<end])
            routeEffects()
            refreshInputModes()
            updateRenderHold()
            markRenderPending()
            if countedAsPending { consumePending(end - offset) }
            scheduleResearchIfNeeded()
            offset = end
            guard offset < bytes.count else { break }
            await Task.yield()
            guard epoch == writeEpoch else { return false }
        }
        return true
    }

    private func consumePending(_ count: Int) {
        incoming.withLock { $0.pendingBytes = max(0, $0.pendingBytes - count) }
    }

    /// `attach_overflow` を受けたら、リセットして最初から attach し直す。
    @discardableResult
    public func handleAttachOverflow() -> Bool {
        attach()
    }

    /// 接続が切れた。再接続して attach し直すまで、入力と端末の応答は送らない。
    public func connectionLost() {
        phase = .detached
        _ = drainInput()
        // 積んである出力は捨てる（attach し直すと replay で最初から受け取る）。
        discardIncoming()
        writeEpoch += 1
    }

    // MARK: - ビューから（spec: terminal-rendering「Grid size follows the view」）

    /// ビューのグリッドサイズを反映する。live でグリッドが変わったら `resize` を送る。
    /// 端末のリサイズに失敗したら、前のサイズのままにする（そのサイズを PTY に送ると、シェルと端末の大きさが食い違う）。
    public func setViewGrid(_ grid: GridSize) {
        let previous = viewGrid
        do {
            try terminal.resize(
                cols: grid.cols, rows: grid.rows, cellWidthPx: grid.cellWidthPx, cellHeightPx: grid.cellHeightPx
            )
        } catch {
            Self.log.error(
                "resize to \(grid.cols, privacy: .public)x\(grid.rows, privacy: .public) failed (sid=\(self.sid, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            return
        }
        viewGrid = grid
        // mode 2048 のサイズ報告が出ることがある。リサイズは同期出力の保留も解く。
        routeEffects()
        updateRenderHold()
        // 一致の行と列はリサイズ前のもの（折り返しも変わる）なので、検索し直す。
        // 古い一致のまま描くと、狭めたグリッドの外の列を指してしまう。
        if previous?.cols != grid.cols || previous?.rows != grid.rows {
            refreshSearchMatches()
        }
        markRenderPending()
        if phase == .live, previous?.cols != grid.cols || previous?.rows != grid.rows {
            sendViewSize()
        }
    }

    /// live なら、現在のグリッドサイズで `resize` を送り直す（フォーカスを得たときなど）。
    public func resendViewSize() {
        guard phase == .live else { return }
        sendViewSize()
    }

    // MARK: - 設定の変更（phase4 design D4 / D6）

    /// 既定の配色を差し替えて、全体を描き直す（spec: color-scheme「Scheme applies everywhere」）。
    /// プログラムが OSC で変えた色はそのまま残る。
    public func setColors(_ colors: TerminalColorConfiguration) {
        guard colors != self.colors else { return }
        self.colors = colors
        try? terminal.setColors(colors)
        forceFullSnapshot = true
        markRenderPending()
    }

    /// スクロールバックの上限（`scrollback_lines`）を変える。libghostty はいつでも変えられる
    /// （`GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES`。Sources/TerminalCore/README.md の対応表）。
    public func setMaxScrollback(_ lines: Int) {
        guard lines >= 0, lines != terminal.maxScrollback else { return }
        try? terminal.setMaxScrollback(lines: lines)
        // viewport が新しい上限より古い行にあれば、見せてよい範囲に戻す。
        terminal.clampViewportToScrollbackLimit()
        forceFullSnapshot = true
        markRenderPending()
    }

    /// 設定しているスクロールバックの上限（テスト用）。
    public var maxScrollback: Int {
        terminal.maxScrollback
    }

    // MARK: - 入力（spec: terminal-input / terminal-mouse / terminal-clipboard）

    /// キー入力を積む。メインスレッドの次の周回でまとめて 1 つの `input` フレームにする。
    public nonisolated func enqueueKey(_ key: KeyInput) {
        enqueue(.key(key))
    }

    /// テキストをそのまま送る（Shift+Enter の `ESC CR`、`¥` の `\`、IME で確定した文字列）。
    public nonisolated func enqueueText(_ text: String) {
        enqueue(.text(text))
    }

    /// マウスのイベントを積む。プログラムがマウスの報告を有効にしていて、live のときだけ送る。
    public nonisolated func enqueueMouse(_ mouse: MouseInput) {
        enqueue(.mouse(mouse))
    }

    /// スクロールを積む（報告 → 矢印キー → viewport の順で振り分ける）。
    public nonisolated func enqueueScroll(_ scroll: ScrollInput) {
        enqueue(.scroll(scroll))
    }

    /// キーボードフォーカスの変化を積む。プログラムが focus reporting（DECSET 1004）を有効にしていれば報告する。
    public nonisolated func enqueueFocus(_ focused: Bool) {
        enqueue(.focus(focused))
    }

    /// 選択の操作を積む。
    public nonisolated func enqueueSelection(_ selection: SelectionInput) {
        enqueue(.selection(selection))
    }

    private nonisolated func enqueue(_ item: InputItem) {
        let shouldSchedule = inputBuffer.withLock { buffer -> Bool in
            buffer.items.append(item)
            guard !buffer.flushScheduled else { return false }
            buffer.flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            Task { await self.flushInput() }
        }
    }

    /// 積んである入力を、積んだ順に処理して送る。セッションに送るものは live のときだけ送り、それ以外は捨てる。
    /// viewport のスクロールと選択は、phase に関係なく行う。
    public func flushInput() {
        let items = drainInput()
        guard !items.isEmpty else { return }
        let live = phase == .live
        var bytes: [UInt8] = []
        // セッションに送ったキー入力があれば、viewport を最下部に戻す（spec: terminal-input「Typing returns to the bottom」）。
        var typed = false
        var redraw = false

        for item in items {
            switch item {
            case .key(let key):
                guard live, let encoded = try? terminal.encodeKey(key), !encoded.isEmpty else { continue }
                bytes.append(contentsOf: encoded)
                typed = true
            case .text(let text):
                guard live, !text.isEmpty else { continue }
                bytes.append(contentsOf: text.utf8)
                typed = true
            case .mouse(let mouse):
                guard live, let encoded = try? terminal.encodeMouse(mouse) else { continue }
                bytes.append(contentsOf: encoded)
            case .focus(let focused):
                guard live else { continue }
                bytes.append(contentsOf: terminal.encodeFocus(focused))
            case .scroll(let scroll):
                if let encoded = handleScroll(scroll, live: live) {
                    bytes.append(contentsOf: encoded)
                } else {
                    redraw = true
                }
            case .selection(let selection):
                if (try? terminal.applySelection(selection)) == true {
                    redraw = true
                }
                if case .autoscrollTick = selection.kind {
                    redraw = true
                }
            }
        }

        if typed, terminal.scrollViewportToBottom() {
            redraw = true
        }
        if redraw {
            forceFullSnapshot = true
            markRenderPending()
        }
        sendInput(bytes)
    }

    /// スクロールを振り分ける。セッションに送るならそのバイト列、viewport を動かしたら nil を返す。
    private func handleScroll(_ scroll: ScrollInput, live: Bool) -> [UInt8]? {
        let modes = terminal.inputModes
        let target = scrollTarget(
            mouseTracking: modes.mouseTracking,
            shift: scroll.modifiers.contains(.shift),
            alternateScreen: modes.alternateScreen
        )
        guard scroll.lines != 0 else { return [] }
        let up = scroll.lines > 0
        let count = abs(scroll.lines)
        switch target {
        case .mouseReport:
            guard live else { return [] }
            let wheel = MouseInput(
                action: .press,
                button: up ? .wheelUp : .wheelDown,
                modifiers: scroll.modifiers,
                x: scroll.x,
                y: scroll.y,
                anyButtonPressed: false,
                surface: scroll.surface
            )
            var bytes: [UInt8] = []
            for _ in 0..<count {
                bytes.append(contentsOf: (try? terminal.encodeMouse(wheel)) ?? [])
            }
            return bytes
        case .arrowKeys:
            guard live, let arrow = try? terminal.encodeArrow(up: up) else { return [] }
            return Array([[UInt8]](repeating: arrow, count: count).joined())
        case .viewport:
            return terminal.scrollViewport(by: -scroll.lines) ? nil : []
        }
    }

    /// 積んである入力を処理してから、テキストをペーストする（spec: terminal-clipboard「Paste with Command-V」）。
    /// - Parameter allowUnsafe: 危険なテキストでも送る（利用者が確認した）
    public func paste(_ text: String, allowUnsafe: Bool = false) -> PasteResult {
        flushInput()
        guard phase == .live, !text.isEmpty else { return .ignored }
        guard let bytes = terminal.encodePaste(text, allowUnsafe: allowUnsafe) else { return .needsConfirmation }
        guard !bytes.isEmpty else { return .ignored }
        if terminal.scrollViewportToBottom() {
            forceFullSnapshot = true
            markRenderPending()
        }
        sendInput(bytes)
        return .sent
    }

    /// 積んである入力（選択の操作）を処理してから、選択範囲のテキストを返す。選択が無ければ空。
    public func selectionText() -> String {
        flushInput()
        return (try? terminal.selectionText()) ?? ""
    }

    // MARK: - ビューの状態（phase3 design D1）

    /// 表示を別のセッションに切り替えるときに、未確定の文字列を預ける（nil なら預けたものを消す）。
    public nonisolated func saveComposition(_ composition: ComposingText?) {
        savedComposition.withLock { $0 = composition }
    }

    /// 預けた未確定の文字列を取り出す（取り出したら消える）。
    public nonisolated func takeSavedComposition() -> ComposingText? {
        savedComposition.withLock { saved in
            defer { saved = nil }
            return saved
        }
    }

    /// 入力の振り分けに使うモード（同期的に読める。端末に書き込むたびに更新する）。
    public nonisolated var inputModes: TerminalInputModes {
        modesState.withLock { $0 }
    }

    /// 描画すべき変化があるか（同期的に読める）。同期出力で保留している間は false。
    public nonisolated var needsRender: Bool {
        let now = ContinuousClock.now
        return renderGate.withLock { $0.pending && !$0.isHeld(at: now) }
    }

    /// 同期出力（DECSET 2026）で描画を保留しているか。
    public nonisolated var isRenderHeld: Bool {
        let now = ContinuousClock.now
        return renderGate.withLock { $0.isHeld(at: now) }
    }

    /// 同期出力の保留のタイムアウトを変える（テスト用）。
    func setRenderHoldTimeoutForTesting(_ timeout: Duration) {
        renderGate.withLock { $0.holdTimeout = timeout }
    }

    /// 描画すべき変化が無い状態から、ある状態になったときに呼ぶ処理を設定する（nil で外す）。
    /// どのスレッドからも呼ばれるので、メインスレッドに移ってから処理する。
    public nonisolated func setRenderObserver(_ observer: (@Sendable () -> Void)?) {
        renderObserver.withLock { $0 = observer }
    }

    /// 描画用のスナップショット（変化した行だけ）を作る。
    ///
    /// プログラムが同期出力で更新を止めている間は、途中の画面を見せないよう nil を返す（変化は次に回す）。
    /// - Parameter knownImageGenerations: ビューが中身（テクスチャ）を持っている画像の世代。その中身はコピーしない
    public func makeSnapshot(forceFull: Bool = false, knownImageGenerations: Set<UInt64> = []) -> FrameSnapshot? {
        let now = ContinuousClock.now
        let held = renderGate.withLock { gate -> Bool in
            guard !gate.isHeld(at: now) else { return true }
            gate.pending = false
            return false
        }
        guard !held else { return nil }
        let full = forceFull || forceFullSnapshot
        forceFullSnapshot = false
        var snapshot: FrameSnapshot
        do {
            snapshot = try terminal.makeSnapshot(forceFull: full, knownImageGenerations: knownImageGenerations)
        } catch {
            // 途中で失敗すると dirty の印は消えているかもしれないので、次は全行を取り直す。
            forceFullSnapshot = true
            if !snapshotFailing {
                Self.log.error("snapshot failed (sid=\(self.sid, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
            snapshotFailing = true
            return nil
        }
        snapshotFailing = false
        snapshot.searchHighlights = viewportSearchHighlights(cols: snapshot.cols, rows: snapshot.rows)
        return snapshot
    }

    // MARK: - リンク（spec: terminal-links、phase5 design D6）

    /// viewport のセルにある OSC 8 のリンク。素の URL は、ビューが表示しているセルから探す（`LinkDetector.plainLink`）。
    public func hyperlink(at point: GridPoint) -> TerminalLink? {
        terminal.hyperlink(at: point)
    }

    // MARK: - 検索（spec: terminal-search、phase5 design D5）

    /// `query` で検索し、最初の一致（いちばん上）を今の一致にして、見えるところまで viewport を動かす。
    /// 一致が無ければ viewport は動かさない。空の文字列なら検索をやめる。
    @discardableResult
    public func search(_ query: String) -> SearchStatus {
        flushInput()
        searchQuery = query
        guard !query.isEmpty else {
            endSearch()
            return .empty
        }
        searchMatches = (try? terminal.search(query)) ?? []
        searchIndex = searchMatches.isEmpty ? nil : 0
        scrollToCurrentMatch()
        forceFullSnapshot = true
        markRenderPending()
        return searchStatus
    }

    /// 次の一致（下）に移る。最後の一致の次は最初の一致。
    @discardableResult
    public func searchNext() -> SearchStatus {
        moveSearch(by: 1)
    }

    /// 前の一致（上）に移る。最初の一致の前は最後の一致。
    @discardableResult
    public func searchPrevious() -> SearchStatus {
        moveSearch(by: -1)
    }

    /// 検索をやめ、強調を消す。
    public func endSearch() {
        let hadMatches = !searchMatches.isEmpty
        searchQuery = ""
        searchMatches = []
        searchIndex = nil
        researchScheduled = false
        terminal.endSearch()
        if hadMatches {
            forceFullSnapshot = true
            markRenderPending()
        }
    }

    /// 今の検索の状態。
    public var searchStatus: SearchStatus {
        SearchStatus(query: searchQuery, total: searchMatches.count, current: searchIndex)
    }

    /// 今の一致（テスト用）。
    public var currentSearchMatch: SearchMatch? {
        searchIndex.map { searchMatches[$0] }
    }

    /// 新しい出力のあとに検索し直した結果を知らせる（nil で外す）。どのスレッドからも呼ばれる。
    public nonisolated func setSearchObserver(_ observer: (@Sendable (SearchStatus) -> Void)?) {
        searchObserver.withLock { $0 = observer }
    }

    private func moveSearch(by delta: Int) -> SearchStatus {
        flushInput()
        guard !searchMatches.isEmpty else { return searchStatus }
        let count = searchMatches.count
        let current = searchIndex ?? (delta > 0 ? -1 : 0)
        searchIndex = ((current + delta) % count + count) % count
        scrollToCurrentMatch()
        forceFullSnapshot = true
        markRenderPending()
        return searchStatus
    }

    private func scrollToCurrentMatch() {
        guard let match = currentSearchMatch else { return }
        terminal.scrollToShow(match)
    }

    /// 新しい出力が来たら、`researchDelay` のあとに検索し直す（その間の出力はまとめる）。
    private func scheduleResearchIfNeeded() {
        guard !searchQuery.isEmpty, !researchScheduled else { return }
        researchScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: TerminalController.researchDelay)
            await self?.research()
        }
    }

    /// 検索し直す。今の一致が残っていればそのまま、無くなっていれば近い番号にする。viewport は動かさない。
    private func research() {
        guard researchScheduled else { return }
        researchScheduled = false
        refreshSearchMatches()
    }

    /// 今の検索語で一致を取り直す。今の一致が残っていればそのまま、無くなっていれば近い番号にする。viewport は動かさない。
    private func refreshSearchMatches() {
        guard !searchQuery.isEmpty else { return }
        let previous = currentSearchMatch
        let previousIndex = searchIndex
        searchMatches = (try? terminal.search(searchQuery)) ?? []
        if searchMatches.isEmpty {
            searchIndex = nil
        } else if let previous, let same = searchMatches.firstIndex(of: previous) {
            searchIndex = same
        } else {
            searchIndex = min(previousIndex ?? 0, searchMatches.count - 1)
        }
        forceFullSnapshot = true
        markRenderPending()
        publishSearchStatus()
    }

    private func publishSearchStatus() {
        let status = searchStatus
        searchObserver.withLock { $0 }?(status)
    }

    /// viewport の行ごとの一致の列（スナップショットに入れる）。
    private func viewportSearchHighlights(cols: Int, rows: Int) -> [Int: [SearchHighlight]] {
        guard !searchMatches.isEmpty, cols > 0, rows > 0 else { return [:] }
        let top = terminal.viewportOffset
        let bottom = top + rows - 1
        // 一致は上から順なので、viewport より前で終わる一致を二分探索で飛ばす。
        var low = 0
        var high = searchMatches.count
        while low < high {
            let middle = (low + high) / 2
            if searchMatches[middle].endRow < top { low = middle + 1 } else { high = middle }
        }
        var highlights: [Int: [SearchHighlight]] = [:]
        var index = low
        while index < searchMatches.count, searchMatches[index].startRow <= bottom {
            let match = searchMatches[index]
            let isCurrent = index == searchIndex
            for row in max(match.startRow, top)...min(match.endRow, bottom) {
                let first = row == match.startRow ? match.startColumn : 0
                let last = min(row == match.endRow ? match.endColumn : cols - 1, cols - 1)
                // グリッドの外を指す一致（リサイズの直後など）は描かない。
                guard first <= last else { continue }
                highlights[row - top, default: []].append(SearchHighlight(columns: first...last, isCurrent: isCurrent))
            }
            index += 1
        }
        return highlights
    }

    /// 画面の plain テキスト（テスト・デバッグ用）。
    public func plainText() -> String {
        (try? terminal.plainText()) ?? ""
    }

    /// 端末のモード（テスト用）。
    func setTerminalModeForTesting(_ bytes: [UInt8]) {
        terminal.write(bytes)
        _ = terminal.takeEffects()
        refreshInputModes()
        updateRenderHold()
    }

    /// テスト用: 端末を直接触る。
    func withTerminal<T: Sendable>(_ body: @Sendable (VTTerminal) throws -> T) rethrows -> T {
        try body(terminal)
    }

    // MARK: - 内部

    /// effect を phase で振り分ける（design D2 の表）。
    private func routeEffects() {
        var reply: [UInt8] = []
        for effect in terminal.takeEffects() {
            switch effect {
            case .ptyWrite(let bytes):
                // replay 中の応答は過去の問い合わせへのものなので、シェルの入力行に入れないよう捨てる。
                if phase == .live {
                    reply.append(contentsOf: bytes)
                }
            case .clipboardWrite(let text):
                // replay の中の書き込みは過去のものなので、クリップボードを書き換えない。
                if phase == .live {
                    clipboard?.write(text)
                }
            case .bell, .titleChanged, .desktopNotification:
                // ベルは鳴らさない（Web 版と同じ）。タイトルはタブ名に使わない。通知はデーモンの notify に任せる。
                break
            }
        }
        sendInput(reply)
    }

    private func sendInput(_ bytes: [UInt8]) {
        guard phase == .live, !bytes.isEmpty else { return }
        sink.enqueue(.input(sid: sid, bytes: bytes))
    }

    private func sendViewSize() {
        guard let viewGrid else { return }
        sink.enqueue(.resize(sid: sid, cols: viewGrid.cols, rows: viewGrid.rows))
    }

    private func drainInput() -> [InputItem] {
        inputBuffer.withLock { buffer in
            defer {
                buffer.items.removeAll()
                buffer.flushScheduled = false
            }
            return buffer.items
        }
    }

    private func refreshInputModes() {
        let modes = terminal.inputModes
        modesState.withLock { $0 = modes }
    }

    private func markRenderPending() {
        let wasPending = renderGate.withLock { gate -> Bool in
            defer { gate.pending = true }
            return gate.pending
        }
        if !wasPending {
            notifyRenderObserver()
        }
    }

    private func notifyRenderObserver() {
        renderObserver.withLock { $0 }?()
    }

    /// 同期出力の開始と終了を、描画の保留に反映する（phase5 design D4）。
    private func updateRenderHold() {
        let held = terminal.isRenderHeld
        let now = ContinuousClock.now
        let change = renderGate.withLock { gate -> Bool? in
            if held, gate.heldSince == nil {
                gate.heldSince = now
                return true
            }
            if !held, gate.heldSince != nil {
                gate.heldSince = nil
                return false
            }
            return nil
        }
        switch change {
        case true?:
            // 解除されないまま時間が過ぎたら、そこまでの画面を描く。
            renderHoldGeneration += 1
            let generation = renderHoldGeneration
            let timeout = renderGate.withLock { $0.holdTimeout }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.renderHoldTimedOut(generation)
            }
        case false?:
            // 解除された。完成した画面をすぐに描く（保留している間に display link が止まっていることがある）。
            notifyRenderObserver()
        case nil:
            break
        }
    }

    private func renderHoldTimedOut(_ generation: Int) {
        guard generation == renderHoldGeneration, renderGate.withLock({ $0.heldSince != nil && $0.pending }) else { return }
        notifyRenderObserver()
    }
}
