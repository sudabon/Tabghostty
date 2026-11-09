import AppKit
import DesktopSupport

/// 起動に失敗したときの画面（エラー文と再試行ボタン）。spec: app-shell「Startup failure screen」。
@MainActor
final class StartupFailureView: NSView {
    private let messageField = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    var onRetry: (() -> Void)?

    init() {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: "Tabghostty could not start")
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 4, weight: .semibold)

        messageField.isSelectable = true
        messageField.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageField.textColor = .secondaryLabelColor
        messageField.preferredMaxLayoutWidth = 560

        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.keyEquivalent = "\r"
        retryButton.bezelStyle = .rounded

        let stack = NSStackView(views: [title, messageField, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            messageField.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var message: String {
        get { messageField.stringValue }
        set { messageField.stringValue = newValue }
    }

    var isRetrying: Bool = false {
        didSet {
            retryButton.isEnabled = !isRetrying
            retryButton.title = isRetrying ? "Retrying…" : "Retry"
        }
    }

    @objc private func retry() {
        onRetry?()
    }
}

/// 接続を待っている間の表示。
@MainActor
final class ConnectingView: NSView {
    init() {
        super.init(frame: .zero)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Connecting to the webtabinal daemon…")
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// 一時的なメッセージ（トースト）。5 秒で消え、閉じるボタンでも消せる。モーダルにしない。
/// spec: app-shell「Transient error messages」。
@MainActor
final class ToastView: NSVisualEffectView {
    static let duration: Duration = .seconds(5)

    private let label = NSTextField(wrappingLabelWithString: "")
    private var dismissTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        isHidden = true

        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.textColor = .labelColor
        label.isSelectable = true
        label.maximumNumberOfLines = 4

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss") ?? NSImage(),
            target: nil,
            action: nil
        )
        close.isBordered = false
        close.target = self
        close.action = #selector(dismiss)
        close.setAccessibilityLabel("Dismiss")

        let stack = NSStackView(views: [label, close])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// メッセージを出す。前のメッセージは置き換える。
    func show(_ message: String) {
        label.stringValue = message
        isHidden = false
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    @objc func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        isHidden = true
    }
}

/// 接続が切れている理由（帯の文言とボタンを決める）。
enum ConnectionLostReason: Equatable, Sendable {
    /// デーモンは動いている（か、まだ分からない）。再接続を続ける。
    case reconnecting
    /// デーモンが待ち受けていない。起動するボタンを出す。
    case daemonStopped
    /// ほかのプログラムがポートを使っている。起動の手順をやり直すボタンを出す。
    case portInUse(port: Int)
    /// デーモンがトークンを拒否した（HTTP 401 / 403。config.json が作り直されたなど）。
    /// 同じトークンでは何度再接続しても通らないので、config.json を読み直してつなぎ直すボタンを出す。
    case rejected(status: Int)

    /// 切れている間のプローブの結果から決める。応答を読み切れないもの（`unverified`）は、忙しいデーモンかもしれないので再接続を待つ。
    init(probe: WebTabinalProbeResult, port: Int) {
        switch probe {
        case .daemon, .unverified: self = .reconnecting
        case .notListening: self = .daemonStopped
        case .foreign: self = .portInUse(port: port)
        }
    }

    fileprivate var message: String {
        switch self {
        case .reconnecting:
            "Disconnected from the webtabinal daemon. Reconnecting…"
        case .daemonStopped:
            "The webtabinal daemon is not running. Typing does not reach the terminal."
        case .portInUse(let port):
            "Another program is using port \(port), so Tabghostty cannot reach the webtabinal daemon."
        case .rejected(let status):
            "The webtabinal daemon rejected Tabghostty's token (HTTP \(status)). config.json may have changed."
        }
    }

    /// ボタンの名前（ボタンを出さないなら nil）。
    fileprivate var actionTitle: String? {
        switch self {
        case .reconnecting: nil
        case .daemonStopped: "Start Daemon"
        case .portInUse: "Retry"
        case .rejected: "Reconnect"
        }
    }
}

/// デーモンとの接続が切れている間、ウィンドウの上に出す帯。切れている間はキー入力が端末に届かないことを知らせる。
/// 利用者が何かできるとき（デーモンが止まっている、トークンが拒否されたなど）は、ボタンを出す
/// （勝手にはデーモンを起動しない。利用者が別のデーモンに切り替えている途中かもしれないため）。
@MainActor
final class ConnectionLostBannerView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var onAction: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        actionButton.target = self
        actionButton.action = #selector(performAction)
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small

        let stack = NSStackView(views: [spinner, label, actionButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 出す。ボタンのある理由なら、押したときに `onAction` を一度だけ呼ぶ（もう一度出すまでは押せない）。
    func show(_ reason: ConnectionLostReason, onAction: @escaping () -> Void) {
        label.stringValue = reason.message
        if let title = reason.actionTitle {
            self.onAction = onAction
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            actionButton.title = title
            actionButton.isHidden = false
            actionButton.isEnabled = true
        } else {
            self.onAction = nil
            spinner.isHidden = false
            spinner.startAnimation(nil)
            actionButton.isHidden = true
        }
        isHidden = false
    }

    func hide() {
        onAction = nil
        spinner.stopAnimation(nil)
        isHidden = true
    }

    /// 表示している文言（テスト用）。
    var message: String { isHidden ? "" : label.stringValue }

    /// 出しているボタンの名前（テスト用）。ボタンを出していなければ nil。
    var actionTitle: String? { isHidden || actionButton.isHidden ? nil : actionButton.title }

    /// ボタンを押す（テスト用）。
    func clickActionForTesting() {
        actionButton.performClick(nil)
    }

    @objc private func performAction() {
        actionButton.isEnabled = false
        onAction?()
    }
}
