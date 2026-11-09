/// display link を動かすか止めるかを決める（phase5 design D3）。
///
/// - 描くもの（端末の変化、描画の実装の変化、取りに行っているスナップショット）が無い tick が `idleTimeout` 続いたら止める。
/// - 出力・入力・カーソルの点滅などで変化が起きたら（`activity`）再開する。
/// - ウィンドウが見えていない（最小化、ほかのウィンドウに完全に隠れた）間は、変化があっても止めたままにする。
struct FramePacer {
    /// 変化が無いまま、この時間が過ぎたら止める。
    static let idleTimeout: Duration = .seconds(1)

    private(set) var isPaused = false
    private(set) var isVisible = true
    private var lastActivity: ContinuousClock.Instant

    init(now: ContinuousClock.Instant = .now) {
        lastActivity = now
    }

    /// 変化が起きた。止めていたなら再開するので true を返す。
    /// - Parameter countsAsActivity: false なら、1 フレーム描くために再開するが、止めるまでの時計は戻さない
    ///   （カーソルの点滅。点滅は `idleTimeout` より短い間隔で続くので、数えると止まらなくなる）
    mutating func activity(at now: ContinuousClock.Instant = .now, countsAsActivity: Bool = true) -> Bool {
        if countsAsActivity {
            lastActivity = now
        }
        guard isPaused, isVisible else { return false }
        isPaused = false
        return true
    }

    /// display link の tick。止めるなら true を返す。
    /// - Parameter busy: この tick の後も描くものが残っている
    mutating func tick(at now: ContinuousClock.Instant = .now, busy: Bool) -> Bool {
        guard !isPaused else { return false }
        if !isVisible {
            isPaused = true
            return true
        }
        if busy {
            lastActivity = now
            return false
        }
        guard now - lastActivity >= Self.idleTimeout else { return false }
        isPaused = true
        return true
    }

    /// ウィンドウが見えるようになった / 見えなくなった。
    /// - Returns: display link を止めるなら false、再開するなら true
    mutating func setVisible(_ visible: Bool, at now: ContinuousClock.Instant = .now) -> Bool {
        isVisible = visible
        if visible {
            lastActivity = now
            isPaused = false
            return true
        }
        isPaused = true
        return false
    }
}
