import AppKit
import TerminalCore
import TerminalUI

/// キーの記録（設定画面の「キーボード」。spec: settings-window「Keyboard category」、phase4 design D3）。
///
/// 記録を始めたら、次に押したキー 1 つを `Keymap.normalize` の表記にして `onRecord` で渡す。
/// - Escape で取り消す（`onCancel`）。
/// - 修飾キーだけの入力（と、表記にできないキー）は無視して、記録を続ける。
/// - 記録している間のキーは、メニューのショートカット（Command-N など）を含めてアプリに渡さない。
@MainActor
public final class KeyRecorder {
    public private(set) var isRecording = false
    /// 記録したキー（表記）。
    public var onRecord: ((String) -> Void)?
    /// 記録を取り消した。
    public var onCancel: (() -> Void)?

    private var monitor: Any?
    private static let escapeKeyCode: UInt16 = 0x35

    public init() {}

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// 記録を始める。
    /// - Parameter monitorEvents: アプリのキー入力を監視する（テストでは false にして `handle` を直接呼ぶ）
    public func start(monitorEvents: Bool = true) {
        stopMonitoring()
        isRecording = true
        guard monitorEvents else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let stroke = KeyStroke(event: event, phase: .down, isComposing: false)
            return MainActor.assumeIsolated { self.handle(stroke) } ? nil : event
        }
    }

    /// 記録をやめる（何も知らせない）。
    public func stop() {
        isRecording = false
        stopMonitoring()
    }

    /// キーを押した。記録中なら消費して true を返す。
    @discardableResult
    public func handle(_ stroke: KeyStroke) -> Bool {
        guard isRecording, stroke.phase == .down else { return false }
        if stroke.keyCode == Self.escapeKeyCode {
            stop()
            onCancel?()
            return true
        }
        guard let spec = Keymap.normalize(stroke) else {
            // 修飾キーだけ・表記にできないキーは無視して、次のキーを待つ。
            return true
        }
        stop()
        onRecord?(spec)
        return true
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
