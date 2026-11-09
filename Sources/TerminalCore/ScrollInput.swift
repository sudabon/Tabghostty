/// ホイール・トラックパッドのスクロール 1 回分（spec: terminal-mouse「Scroll wheel and trackpad」）。
public struct ScrollInput: Equatable, Sendable {
    /// 動かす行数。正なら上（古い行の方向。ホイールを手前から奥へ回す、トラックパッドで下へスワイプする）。
    public var lines: Int
    /// ポインタの位置（surface 座標、device pixel）。マウスの報告に使う。
    public var x: Double
    public var y: Double
    public var modifiers: KeyInput.Modifiers
    public var surface: MouseSurface

    public init(lines: Int, x: Double, y: Double, modifiers: KeyInput.Modifiers = [], surface: MouseSurface) {
        self.lines = lines
        self.x = x
        self.y = y
        self.modifiers = modifiers
        self.surface = surface
    }
}

/// スクロールの行き先。
public enum ScrollTarget: Equatable, Sendable {
    /// プログラムにホイールのイベントとして報告する。
    case mouseReport
    /// 上下の矢印キーを、1 行につき 1 回送る（xterm.js と同じ。less などのページャ向け）。
    case arrowKeys
    /// viewport をスクロールバックの中で動かす（セッションには何も送らない）。
    case viewport
}

/// スクロールをどこに送るかを決める（spec の順序。phase2 design D5）。
///
/// 1. プログラムがマウスの報告を有効にしていれば、報告する（Shift を押していれば報告しない）。
/// 2. そうでなく、alternate screen なら矢印キーにする。
/// 3. それ以外は viewport を動かす。
public func scrollTarget(mouseTracking: MouseTracking, shift: Bool, alternateScreen: Bool) -> ScrollTarget {
    if mouseTracking != .none && !shift {
        return .mouseReport
    }
    if alternateScreen {
        return .arrowKeys
    }
    return .viewport
}

/// スクロール量を行数にする（precise なトラックパッドの量は溜めて、セルの高さごとに 1 行にする）。
public struct ScrollAccumulator: Equatable, Sendable {
    /// まだ行にならない量（precise ならポイント、そうでなければ行）。
    public private(set) var pending: Double = 0

    public init() {}

    /// スクロール量を足し、動かす行数（上が正）を返す。
    /// - Parameters:
    ///   - delta: `NSEvent.scrollingDeltaY`（上が正）
    ///   - precise: `NSEvent.hasPreciseScrollingDeltas`（トラックパッドなど。量はポイント）
    ///   - cellHeight: セルの高さ（ポイント）
    public mutating func add(_ delta: Double, precise: Bool, cellHeight: Double) -> Int {
        guard delta != 0, delta.isFinite else { return 0 }
        // 向きが変わったら、前の向きの端数は捨てる。
        if pending != 0, (pending > 0) != (delta > 0) {
            pending = 0
        }
        // ホイールは行数で届く（加速すると 1 より大きい）。端数は溜める。
        pending += precise ? delta / max(cellHeight, 1) : delta
        let lines = Int(pending.rounded(.towardZero))
        pending -= Double(lines)
        return lines
    }

    /// 溜めた端数を捨てる（新しいスクロールの操作を始めたとき）。
    public mutating func reset() {
        pending = 0
    }
}
