import AppKit
import DaemonClient
import TerminalCore
import TerminalUI

/// メインウィンドウ（spec: app-shell「Main window」）。
///
/// 中身は「接続中」「起動失敗」「端末」のどれか 1 つで、その上にトーストを重ねる。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let initialSize = NSSize(width: 1100, height: 720)
    static let autosaveName = "TabghosttyMain"

    private let container = NSView()
    private let toast = ToastView()
    private var content: NSView?
    private(set) var terminalView: TerminalView?
    private var failureView: StartupFailureView?

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = WindowTitle.appName
        window.minSize = NSSize(width: 320, height: 200)
        window.isReleasedWhenClosed = false
        window.center()
        // 前回の位置と大きさを覚えておき、次の起動で戻す。
        window.setFrameAutosaveName(Self.autosaveName)
        super.init(window: window)
        window.delegate = self

        container.autoresizingMask = [.width, .height]
        window.contentView = container

        toast.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 中身の切り替え

    func showConnecting() {
        terminalView = nil
        failureView = nil
        setContent(ConnectingView())
        window?.title = WindowTitle.appName
    }

    func showStartupFailure(_ message: String, retry: @escaping () -> Void) {
        terminalView = nil
        let view = StartupFailureView()
        view.message = message
        view.onRetry = { [weak view] in
            view?.isRetrying = true
            retry()
        }
        failureView = view
        setContent(view)
        window?.title = WindowTitle.appName
        window?.makeFirstResponder(nil)
    }

    func showTerminal(_ view: TerminalView, background: ColorRGB) {
        failureView = nil
        terminalView = view
        setContent(view)
        window?.backgroundColor = NSColor(
            srgbRed: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255, blue: CGFloat(background.b) / 255, alpha: 1
        )
        window?.makeFirstResponder(view)
    }

    func showToast(_ message: String) {
        toast.show(message)
    }

    func updateTitle(cwd: String?) {
        window?.title = WindowTitle.make(cwd: cwd)
    }

    private func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view, positioned: .below, relativeTo: toast)
        content = view
    }
}
