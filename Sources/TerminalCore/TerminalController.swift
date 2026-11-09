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

/// セッション 1 つ分の端末。VT ハンドルへのアクセスはすべてこの actor を通す
/// （spec: terminal-engine「Serialized access per terminal」、design D1）。
///
/// attach / replay / live のライフサイクル（spec: terminal-session）と、effect の振り分け（design D2）、
/// 入力のまとめ送り（spec: terminal-input）を受け持つ。
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
    private let colors: TerminalColorConfiguration?

    public private(set) var phase: Phase = .detached
    /// ビューから受け取ったグリッドのサイズ。まだ受け取っていなければ nil（resize フレームを送らない）。
    public private(set) var viewGrid: GridSize?

    /// キー入力のバッファ（メインスレッドから同期的に積む）。
    private nonisolated let keyBuffer = OSAllocatedUnfairLock(initialState: KeyBuffer())
    /// 描画すべき変化があるか（ビューの display link から同期的に読む）。
    private nonisolated let renderPending = OSAllocatedUnfairLock(initialState: true)
    /// 次のスナップショットを全行にするか。
    private var forceFullSnapshot = true

    private struct KeyBuffer {
        var keys: [KeyInput] = []
        var flushScheduled = false
    }

    /// - Parameters:
    ///   - sid: セッション ID
    ///   - cols / rows: ビューのサイズが分かるまで使う初期サイズ
    ///   - maxScrollback: `scrollback_lines`
    ///   - colors: 既定の配色。nil なら libghostty の既定値
    ///   - sink: フレームの送り先
    public init(
        sid: String,
        cols: Int = 80,
        rows: Int = 24,
        maxScrollback: Int,
        colors: TerminalColorConfiguration?,
        sink: any TerminalFrameSink
    ) throws {
        self.sid = sid
        self.sink = sink
        self.colors = colors
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
        _ = drainKeys()
        terminal.reset()
        if let colors {
            try? terminal.setColors(colors)
        }
        _ = terminal.takeEffects()
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
        _ = drainKeys()
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

    /// キー入力を積む。メインスレッドの次の周回でまとめて 1 つの `input` フレームにする。
    public nonisolated func enqueueKey(_ key: KeyInput) {
        let shouldSchedule = keyBuffer.withLock { buffer -> Bool in
            buffer.keys.append(key)
            guard !buffer.flushScheduled else { return false }
            buffer.flushScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            Task { await self.flushKeys() }
        }
    }

    /// 積んであるキー入力をエンコードして送る。live でなければ捨てる。
    public func flushKeys() {
        let keys = drainKeys()
        guard phase == .live, !keys.isEmpty else { return }
        var bytes: [UInt8] = []
        for key in keys {
            if let encoded = try? terminal.encodeKey(key) {
                bytes.append(contentsOf: encoded)
            }
        }
        sendInput(bytes)
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

    private func drainKeys() -> [KeyInput] {
        keyBuffer.withLock { buffer in
            defer {
                buffer.keys.removeAll()
                buffer.flushScheduled = false
            }
            return buffer.keys
        }
    }

    private func markRenderPending() {
        renderPending.withLock { $0 = true }
    }
}
