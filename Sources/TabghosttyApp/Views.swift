import AppKit

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

/// デーモンとの接続が切れている間、ウィンドウの上に出す帯。切れている間はキー入力が端末に届かないことを知らせる。
/// デーモンが止まっていると分かったら、起動するボタンを出す（勝手には起動しない。利用者が別のデーモンに
/// 切り替えている途中かもしれないため）。
@MainActor
final class ConnectionLostBannerView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start Daemon", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    var onStartDaemon: (() -> Void)?

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
        startButton.target = self
        startButton.action = #selector(startDaemon)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .small

        let stack = NSStackView(views: [spinner, label, startButton])
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

    /// 出す。`daemonStopped` なら、デーモンが待ち受けていないことと、起動するボタンを出す。
    func show(daemonStopped: Bool) {
        if daemonStopped {
            label.stringValue = "The webtabinal daemon is not running. Typing does not reach the terminal."
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            startButton.isHidden = false
            startButton.isEnabled = true
        } else {
            label.stringValue = "Disconnected from the webtabinal daemon. Reconnecting…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
            startButton.isHidden = true
        }
        isHidden = false
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }

    /// 表示している文言（テスト用）。
    var message: String { isHidden ? "" : label.stringValue }

    /// 起動するボタンを出しているか（テスト用）。
    var showsStartButton: Bool { !isHidden && !startButton.isHidden }

    @objc private func startDaemon() {
        startButton.isEnabled = false
        onStartDaemon?()
    }
}
