import DaemonClient
import Foundation
import TerminalCore

/// プレフィックスによるコード（spec: keyboard-shortcuts「Prefix chord for tab navigation」、phase3 design D4）。
///
/// `TerminalView.keyChordHandler` から呼び、端末へのキー送信より前に判定する。プレフィックスと、
/// 保留中に処理したキー・取り消しに使ったキーは消費する（端末に送らない）。
@MainActor
public final class ChordController {
    /// `key_bindings` の設定。無効、または検証に通らない設定なら、すべてのキーを端末に通す。
    public var bindings: KeyBindings {
        didSet {
            if !isEnabled { cancel() }
        }
    }

    /// プレフィックスを押して保留中か。
    public private(set) var isPending = false
    /// コードを判定しない状態（設定画面やメモの編集シートを開いている、テキストフィールドにフォーカスがある）。
    public var isSuspended: () -> Bool = { false }

    /// 保留中に押したキーの操作（`.next` / `.prev` / `.toggleSidebar`）。
    public var onAction: ((ChordAction) -> Void)?
    /// 保留の状態が変わった（保留中の表示を出す・消す）。
    public var onPendingChange: ((Bool) -> Void)?

    /// 保留を取り消すまでの秒数（テストで短くする）。
    var timeout: Double
    private var timeoutWork: DispatchWorkItem?

    /// - Parameter timeout: 保留を取り消すまでの秒数（既定は 3 秒。テストで短くする）
    public init(bindings: KeyBindings, timeout: Double = Keymap.chordTimeout) {
        self.bindings = bindings
        self.timeout = timeout
    }

    /// コードが有効か（`enabled` が true で、設定が検証に通る）。
    public var isEnabled: Bool {
        bindings.enabled && Keymap.validate(bindings) == nil
    }

    /// 保留中に表示する文字列（`Ctrl+J …`）。
    public var pendingIndicatorText: String {
        "\(Keymap.format(bindings.prefix)) …"
    }

    /// キーを押した。消費したら true（そのキーは端末に送らない）。
    public func handle(_ stroke: KeyStroke) -> Bool {
        guard stroke.phase == .down, isEnabled else { return false }
        guard !isSuspended() else {
            cancel()
            return false
        }
        let resolution = Keymap.resolve(pending: isPending, spec: Keymap.normalize(stroke), bindings: bindings)
        switch resolution.action {
        case .none:
            return false
        case .arm:
            arm()
            return true
        case .cancel:
            cancel()
            return true
        case .next, .prev, .toggleSidebar:
            cancel()
            onAction?(resolution.action)
            return true
        }
    }

    /// 保留を取り消す（時間切れ、ウィンドウがフォーカスを失った、シートを開いた）。
    public func cancel() {
        timeoutWork?.cancel()
        timeoutWork = nil
        setPending(false)
    }

    /// 保留にして、3 秒を数え始める（保留中にもう一度押したら数え直す）。
    private func arm() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.timeoutWork = nil
                self?.setPending(false)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        setPending(true)
    }

    private func setPending(_ pending: Bool) {
        guard isPending != pending else { return }
        isPending = pending
        onPendingChange?(pending)
    }
}
