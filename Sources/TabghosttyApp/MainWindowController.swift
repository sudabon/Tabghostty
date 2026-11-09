import AppKit
import DaemonClient
import Shell
import TerminalCore
import TerminalUI

/// メインウィンドウ（spec: app-shell「Main window」）。
///
/// 中身は「接続中」「起動失敗」「サイドバーと端末」のどれか 1 つで、その上にトーストとコードの保留中の表示を重ねる。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let initialSize = NSSize(width: 1100, height: 720)
    static let autosaveName = "TabghosttyMain"

    private let container = NSView()
    private let toast = ToastView()
    private let connectionBanner = ConnectionLostBannerView()
    private let chordIndicator = ChordIndicatorView()
    private var content: NSView?
    private(set) var shell: TabShellController?
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
        chordIndicator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chordIndicator)
        connectionBanner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(connectionBanner)
        NSLayoutConstraint.activate([
            // 接続が切れたときの帯は、ウィンドウの上中央。
            connectionBanner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            connectionBanner.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            connectionBanner.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
            // コードの保留中の表示は、ウィンドウの下中央（spec: keyboard-shortcuts）。
            chordIndicator.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            chordIndicator.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 中身の切り替え

    func showConnecting() {
        shell = nil
        failureView = nil
        hideConnectionLost()
        showChordIndicator(nil)
        setContent(ConnectingView())
        window?.title = WindowTitle.appName
    }

    func showStartupFailure(_ message: String, retry: @escaping () -> Void) {
        shell = nil
        hideConnectionLost()
        showChordIndicator(nil)
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

    func showShell(_ shell: TabShellController) {
        failureView = nil
        self.shell = shell
        setContent(shell.splitViewController.view)
        applyTheme(shell.appearance.theme)
        if let window {
            shell.attach(to: window)
        }
        shell.focusTerminal()
    }

    /// 配色をウィンドウの背景・外観とコードの表示に合わせる（spec: color-scheme「Scheme applies everywhere」）。
    func applyTheme(_ theme: ResolvedTheme) {
        chordIndicator.palette = theme.chrome
        window?.backgroundColor = theme.chrome.background.nsColor
        window?.appearance = theme.appearance
    }

    /// コードの保留中の表示（nil なら隠す）。
    func showChordIndicator(_ text: String?) {
        chordIndicator.text = text
    }

    func showToast(_ message: String) {
        toast.show(message)
    }

    /// デーモンとの接続が切れていることを出す。`daemonStopped` なら、デーモンを起動するボタンも出す。
    func showConnectionLost(daemonStopped: Bool, onStartDaemon: @escaping () -> Void) {
        connectionBanner.onStartDaemon = onStartDaemon
        connectionBanner.show(daemonStopped: daemonStopped)
    }

    func hideConnectionLost() {
        connectionBanner.onStartDaemon = nil
        connectionBanner.hide()
    }

    /// 接続が切れたときの帯（テスト用）。
    var connectionLostBanner: ConnectionLostBannerView { connectionBanner }

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
