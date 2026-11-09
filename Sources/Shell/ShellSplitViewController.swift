import AppKit
import TerminalUI

/// サイドバーと端末の領域を左右に並べる（phase3 design D2、spec: tab-sidebar「Sidebar layout」「Sidebar collapse」）。
///
/// - サイドバーの幅は `sidebar_width` から始め、160〜480 に収める。ドラッグを離したら `onSidebarWidthCommitted` で知らせる。
/// - 折りたたんだ状態は保存しない（起動するたびに表示する）。
@MainActor
public final class ShellSplitViewController: NSSplitViewController {
    public nonisolated static let minimumSidebarWidth: CGFloat = 160
    public nonisolated static let maximumSidebarWidth: CGFloat = 480

    public let sidebarController: SidebarViewController
    public let terminalArea: TerminalAreaViewController
    public private(set) var sidebarItem: NSSplitViewItem!
    private var contentItem: NSSplitViewItem!
    private var initialSidebarWidth: CGFloat
    private var didApplyInitialWidth = false
    private var widthAtDragStart: CGFloat?
    /// 折りたたんでいる間に設定の幅が変わった（展開したときに使う）。
    private var widthToApplyOnExpand: CGFloat?

    /// ドラッグでサイドバーの幅を変え、離した（四捨五入した幅）。
    public var onSidebarWidthCommitted: ((Int) -> Void)?
    /// 折りたたむ・展開する操作をした（ターミナルにフォーカスを戻す）。
    public var onSidebarToggled: (() -> Void)?

    public init(sidebar: SidebarViewController, terminalArea: TerminalAreaViewController, sidebarWidth: Int) {
        sidebarController = sidebar
        self.terminalArea = terminalArea
        initialSidebarWidth = Self.clampedWidth(CGFloat(sidebarWidth))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 幅を 160〜480 に収める。
    public nonisolated static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

    public override func loadView() {
        let splitView = ShellSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.dividerColorOverride = sidebarController.palette.border.nsColor
        splitView.onDividerDragBegan = { [weak self] in self?.dividerDragBegan() }
        splitView.onDividerDragEnded = { [weak self] in self?.dividerDragEnded() }
        self.splitView = splitView
        super.loadView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        // `NSSplitViewItem(sidebarWithViewController:)` は、macOS 26 ではサイドバーを枠の内側に浮かせて余白を取る
        // （ガラスの外観）。幅の範囲（160〜480）と配色（chrome トークン）を Web 版に合わせるため、ふつうの項目にして、
        // 最小・最大の幅と折りたたみを自分で指定する。
        let sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = Self.minimumSidebarWidth
        sidebarItem.maximumThickness = Self.maximumSidebarWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let contentItem = NSSplitViewItem(viewController: terminalArea)
        contentItem.minimumThickness = 120
        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        self.sidebarItem = sidebarItem
        self.contentItem = contentItem
        terminalArea.onExpandSidebar = { [weak self] in self?.toggleSidebarVisibility() }
        sidebarController.onCollapse = { [weak self] in self?.toggleSidebarVisibility() }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard !didApplyInitialWidth, view.bounds.width > 0 else { return }
        didApplyInitialWidth = true
        splitView.setPosition(initialSidebarWidth, ofDividerAt: 0)
    }

    /// 境界の色を配色に合わせる。
    public func applyPalette(_ palette: ChromePalette) {
        guard isViewLoaded, let splitView = splitView as? ShellSplitView else { return }
        splitView.dividerColorOverride = palette.border.nsColor
        splitView.needsDisplay = true
    }

    // MARK: - 幅（ドラッグで変えて、離したら保存する）

    /// 今のサイドバーの幅。
    public var sidebarWidth: CGFloat {
        sidebarController.view.frame.width
    }

    /// サイドバーの幅を変える（ドラッグと同じ範囲に収める。保存はしない）。
    public func setSidebarWidth(_ width: CGFloat) {
        splitView.setPosition(Self.clampedWidth(width), ofDividerAt: 0)
    }

    /// 設定の幅（`sidebar_width`）が変わった。最初のレイアウトの前なら最初の幅に、折りたたんでいる間なら
    /// 展開したときに使う（spec: settings-window「Configuration changes take effect without restart」）。
    public func applyConfiguredWidth(_ width: Int) {
        let clamped = Self.clampedWidth(CGFloat(width))
        guard didApplyInitialWidth else {
            initialSidebarWidth = clamped
            return
        }
        if isSidebarCollapsed {
            widthToApplyOnExpand = clamped
            return
        }
        widthToApplyOnExpand = nil
        guard abs(sidebarWidth - clamped) >= 0.5 else { return }
        setSidebarWidth(clamped)
    }

    public override func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // ドラッグでは折りたたまない（Web 版と同じく 160 で止める）。折りたたむのはボタンとメニューだけ。
        false
    }

    private func dividerDragBegan() {
        widthAtDragStart = sidebarItem.isCollapsed ? nil : sidebarWidth
    }

    private func dividerDragEnded() {
        defer { widthAtDragStart = nil }
        guard let start = widthAtDragStart, !sidebarItem.isCollapsed else { return }
        let width = Self.clampedWidth(sidebarWidth)
        guard abs(width - start) >= 0.5 else { return }
        onSidebarWidthCommitted?(Int(width.rounded()))
    }

    /// テスト用: ドラッグで幅を変えて離したときと同じことをする。
    func simulateDividerDrag(to width: CGFloat) {
        dividerDragBegan()
        setSidebarWidth(width)
        view.layoutSubtreeIfNeeded()
        dividerDragEnded()
    }

    // MARK: - 折りたたみ

    public var isSidebarCollapsed: Bool {
        sidebarItem?.isCollapsed ?? false
    }

    /// サイドバーを隠す・表示する。終わったら `onSidebarToggled` を呼ぶ。
    public func toggleSidebarVisibility(animated: Bool = true) {
        setSidebarCollapsed(!isSidebarCollapsed, animated: animated)
    }

    public func setSidebarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard let sidebarItem else { return }
        sidebarController.hideMemoTooltip()
        terminalArea.isExpandButtonVisible = collapsed
        if collapsed != sidebarItem.isCollapsed {
            let pendingWidth = collapsed ? nil : widthToApplyOnExpand
            if pendingWidth == nil, animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                sidebarItem.animator().isCollapsed = collapsed
            } else {
                // 折りたたんでいる間に設定の幅が変わっていたら、展開してからその幅にする（アニメーションはしない）。
                sidebarItem.isCollapsed = collapsed
                if let pendingWidth {
                    widthToApplyOnExpand = nil
                    view.layoutSubtreeIfNeeded()
                    setSidebarWidth(pendingWidth)
                }
            }
        }
        onSidebarToggled?()
    }
}

/// サイドバーの境界をドラッグし終えたことを知らせる `NSSplitView`。
///
/// 境界のドラッグは `mouseDown` の中で追跡されるので、`super.mouseDown` から戻ったときがドラッグの終わり。
@MainActor
final class ShellSplitView: NSSplitView {
    var onDividerDragBegan: (() -> Void)?
    var onDividerDragEnded: (() -> Void)?
    var dividerColorOverride: NSColor?

    override var dividerColor: NSColor {
        dividerColorOverride ?? super.dividerColor
    }

    override func mouseDown(with event: NSEvent) {
        onDividerDragBegan?()
        super.mouseDown(with: event)
        onDividerDragEnded?()
    }
}

/// 端末の領域（端末のビュー、折りたたんだときの展開ボタン、すべてのタブを閉じたときの画面）。
@MainActor
public final class TerminalAreaViewController: NSViewController {
    public let terminalView: TerminalView
    public var palette: ChromePalette {
        didSet { applyPalette() }
    }

    var onExpandSidebar: (() -> Void)?
    /// 「すべてのタブを閉じました」の「＋ 新規タブ」。
    public var onNewTab: (() -> Void)?

    private let expandButton = HoverRevealButton()
    private let emptyState = EmptyStateView()

    public init(terminalView: TerminalView, palette: ChromePalette) {
        self.terminalView = terminalView
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func loadView() {
        let root = NSView()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(terminalView)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onNewTab = { [weak self] in self?.onNewTab?() }
        root.addSubview(emptyState)

        expandButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "サイドバーを開く")
        expandButton.setAccessibilityLabel("サイドバーを開く")
        expandButton.toolTip = "サイドバーを開く"
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.refusesFirstResponder = true
        expandButton.target = self
        expandButton.action = #selector(expand)
        expandButton.isHidden = true
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(expandButton)

        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: root.topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            expandButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            expandButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            expandButton.widthAnchor.constraint(equalToConstant: 24),
            expandButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        view = root
        applyPalette()
    }

    private func applyPalette() {
        guard isViewLoaded else { return }
        expandButton.contentTintColor = palette.muted.nsColor
        expandButton.hoverBackground = palette.hover
        emptyState.palette = palette
    }

    /// 折りたたんだときに、端末の左上に展開ボタンを出す。
    public var isExpandButtonVisible: Bool {
        get { !expandButton.isHidden }
        set {
            loadViewIfNeeded()
            expandButton.isHidden = !newValue
        }
    }

    /// 「すべてのタブを閉じました」を出しているか。
    public var isEmptyStateVisible: Bool {
        get { !emptyState.isHidden }
        set {
            loadViewIfNeeded()
            emptyState.isHidden = !newValue
        }
    }

    @objc private func expand() {
        onExpandSidebar?()
    }
}

/// ふだんは薄く、ポインタを乗せると濃くなるボタン（Web 版の `.sidebar-expand`）。
@MainActor
private final class HoverRevealButton: NSButton {
    var hoverBackground = ChromePalette.dark.hover
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        alphaValue = 0.35
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        alphaValue = 1
        layer?.backgroundColor = hoverBackground.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        alphaValue = 0.35
        layer?.backgroundColor = nil
    }
}

/// 「すべてのタブを閉じました」の画面（spec: tab-operations「Behavior when the last tab closes」）。
@MainActor
final class EmptyStateView: NSView {
    var palette = ChromePalette.dark {
        didSet { applyPalette() }
    }

    var onNewTab: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "すべてのタブを閉じました")
    private let newTabButton = NSButton(title: "＋ 新規タブ", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        newTabButton.bezelStyle = .rounded
        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        let stack = NSStackView(views: [titleLabel, newTabButton])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        palette.background.nsColor.setFill()
        dirtyRect.fill()
    }

    private func applyPalette() {
        titleLabel.textColor = palette.text.nsColor
        appearance = palette.appearance
        needsDisplay = true
    }

    @objc private func newTab() {
        onNewTab?()
    }
}

/// コードの保留中に、ウィンドウの下中央に出す表示（spec: keyboard-shortcuts「Pending chord is visible and cancellable」）。
@MainActor
public final class ChordIndicatorView: NSView {
    private let label = NSTextField(labelWithString: "")

    public var palette = ChromePalette.dark {
        didSet { applyPalette() }
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isHidden = true
        setAccessibilityRole(.staticText)
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// 表示する文字列（nil なら隠す）。
    public var text: String? {
        get { isHidden ? nil : label.stringValue }
        set {
            label.stringValue = newValue ?? ""
            setAccessibilityLabel(newValue)
            isHidden = newValue == nil
        }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyPalette() {
        layer?.backgroundColor = palette.sidebar.cgColor
        layer?.borderColor = palette.border.cgColor
        label.textColor = palette.text.nsColor
    }
}
