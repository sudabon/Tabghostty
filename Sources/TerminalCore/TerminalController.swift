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
    /// 描画すべき変化があるか（ビューの display link から同期的に読む）。
    private nonisolated let renderPending = OSAllocatedUnfairLock(initialState: true)
    /// 入力の振り分けに使うモード（ビューから同期的に読む）。端末に書き込むたびに更新する。
    private nonisolated let modesState = OSAllocatedUnfairLock(initialState: TerminalInputModes())
    /// 次のスナップショットを全行にするか。
    private var forceFullSnapshot = true
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
        terminal.reset()
        if let colors {
            try? terminal.setColors(colors)
        }
        _ = terminal.takeEffects()
        refreshInputModes()
        forceFullSnapshot = true
        markRenderPending()

        guard sink.enqueue(.attach(sid: sid)) else {
            phase = .detached
            return false
        }
        phase = .replaying
        return true
    }

    /// `replay` フレームを書き込む。`done` なら live に移り、ビューのグリッドサイズで `resize` を送る。
    public func receiveReplay(_ bytes: [UInt8], done: Bool) {
        guard phase == .replaying else { return }
        terminal.write(bytes)
        routeEffects()
        refreshInputModes()
        markRenderPending()
        if done {
            phase = .live
            sendViewSize()
        }
    }

    /// `output` フレームを書き込む。
    ///
    /// live のときだけ書き込む。replay 中に届く output は、attach より前にデーモンが送り出したもので、
    /// replay の内容（リングバッファ）に含まれているので捨てる（overflow で attach し直したときに内容が重複しない）。
    public func receiveOutput(_ bytes: [UInt8]) {
        guard phase == .live else { return }
        terminal.write(bytes)
        routeEffects()
        refreshInputModes()
        markRenderPending()
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
    }

    // MARK: - ビューから（spec: terminal-rendering「Grid size follows the view」）

    /// ビューのグリッドサイズを反映する。live でグリッドが変わったら `resize` を送る。
    public func setViewGrid(_ grid: GridSize) {
        let previous = viewGrid
        viewGrid = grid
        do {
            try terminal.resize(
                cols: grid.cols, rows: grid.rows, cellWidthPx: grid.cellWidthPx, cellHeightPx: grid.cellHeightPx
            )
        } catch {
            return
        }
        // mode 2048 のサイズ報告が出ることがある。
        routeEffects()
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

    /// 描画すべき変化があるか（同期的に読める）。
    public nonisolated var needsRender: Bool {
        renderPending.withLock { $0 }
    }

    /// 描画用のスナップショット（変化した行だけ）を作る。
    public func makeSnapshot(forceFull: Bool = false) -> FrameSnapshot? {
        renderPending.withLock { $0 = false }
        let full = forceFull || forceFullSnapshot
        forceFullSnapshot = false
        return try? terminal.makeSnapshot(forceFull: full)
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
        renderPending.withLock { $0 = true }
    }
}
