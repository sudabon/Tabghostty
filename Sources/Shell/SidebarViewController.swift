import AppKit
import DaemonClient

/// 左のサイドバー（spec: tab-sidebar「Sidebar layout」、phase3 design D2）。
///
/// デーモンの順序どおりにタブを並べる（自動では並べ替えない）。下に「＋ 新規タブ」と「設定」を置く。
/// 行の操作（選択、メモ、並べ替え、右クリックメニュー）は、コールバックで呼び出し側に任せる。
@MainActor
public final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, TabRowViewDelegate {
    /// メモのツールチップを出すまでの時間（1 秒）。
    public static let memoTooltipDelay: TimeInterval = 1

    public var onSelect: ((String) -> Void)?
    public var onEditMemo: ((String) -> Void)?
    public var onNewTab: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// 並べ替えた後の、すべてのセッションの ID。
    public var onReorder: (([String]) -> Void)?
    public var onMenuAction: ((String, TabMenuItemState.Action) -> Void)?
    public var onCollapse: (() -> Void)?

    public var palette: ChromePalette {
        didSet { applyPalette() }
    }

    /// メモの編集シートを開いている（ツールチップを出さない）。
    public var isMemoEditorOpen = false {
        didSet {
            if isMemoEditorOpen { hideMemoTooltip() }
        }
    }

    public private(set) var sessions: [SessionInfo] = []
    public private(set) var rows: [TabRowModel] = []

    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let collapseButton = NSButton()
    private let newTabButton = DashedButton(title: "＋ 新規タブ")
    private let settingsButton = NSButton()
    private let tooltip: MemoTooltip
    private var tooltipWork: DispatchWorkItem?
    private var hoveredRowID: String?
    private var observers: [NSObjectProtocol] = []
    private var windowResizeObserver: NSObjectProtocol?

    public init(palette: ChromePalette) {
        self.palette = palette
        tooltip = MemoTooltip(palette: palette)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
        }
    }

    // MARK: - ビュー

    public override func loadView() {
        let root = SidebarBackgroundView()
        root.color = palette.sidebar

        collapseButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "サイドバーを閉じる")
        collapseButton.isBordered = false
        collapseButton.imagePosition = .imageOnly
        collapseButton.setAccessibilityLabel("サイドバーを閉じる")
        collapseButton.toolTip = "サイドバーを閉じる"
        collapseButton.target = self
        collapseButton.action = #selector(collapse)
        collapseButton.refusesFirstResponder = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowHeight = TabRowView.height
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.focusRingType = .none
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([.tabghosttySessionID])
        tableView.draggingDestinationFeedbackStyle = .gap
        tableView.setAccessibilityLabel("タブ")

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true

        newTabButton.target = self
        newTabButton.action = #selector(newTab)
        newTabButton.refusesFirstResponder = true

        settingsButton.title = "設定"
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageLeading
        settingsButton.imageHugsTitle = true
        settingsButton.isBordered = false
        settingsButton.font = .systemFont(ofSize: 13)
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.refusesFirstResponder = true

        for view in [collapseButton, scrollView, newTabButton, settingsButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            collapseButton.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            collapseButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            collapseButton.widthAnchor.constraint(equalToConstant: 24),
            collapseButton.heightAnchor.constraint(equalToConstant: 24),

            scrollView.topAnchor.constraint(equalTo: collapseButton.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            newTabButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            newTabButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            newTabButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            newTabButton.heightAnchor.constraint(equalToConstant: 38),

            settingsButton.topAnchor.constraint(equalTo: newTabButton.bottomAnchor, constant: 8),
            settingsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            settingsButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            settingsButton.heightAnchor.constraint(equalToConstant: 34),
            settingsButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
        applyPalette()

        // スクロールしたらツールチップを隠す。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideMemoTooltip() }
        })
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        if let windowResizeObserver {
            NotificationCenter.default.removeObserver(windowResizeObserver)
        }
        // ウィンドウの大きさが変わったらツールチップを隠す（位置がずれるため）。
        windowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: view.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideMemoTooltip() }
        }
    }

    private func applyPalette() {
        guard isViewLoaded else { return }
        (view as? SidebarBackgroundView)?.color = palette.sidebar
        view.appearance = palette.appearance
        collapseButton.contentTintColor = palette.muted.nsColor
        newTabButton.palette = palette
        settingsButton.contentTintColor = palette.muted.nsColor
        settingsButton.attributedTitle = NSAttributedString(string: "設定", attributes: [
            .foregroundColor: palette.muted.nsColor,
            .font: NSFont.systemFont(ofSize: 13),
        ])
        tooltip.palette = palette
        for row in 0..<tableView.numberOfRows {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TabRowView)?.palette = palette
        }
    }

    // MARK: - 表示内容

    /// 一覧・アクティブセッション・未読を反映する。並びが同じなら、見えている行だけを書き換える。
    public func update(sessions: [SessionInfo], activeID: String?, unread: Set<String>) {
        self.sessions = sessions
        let next = sessions.map { TabRowModel(session: $0, isActive: $0.id == activeID, isUnread: unread.contains($0.id)) }
        let sameOrder = next.map(\.id) == rows.map(\.id)
        rows = next
        guard isViewLoaded else { return }
        if sameOrder {
            for (index, model) in rows.enumerated() {
                (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TabRowView)?.configure(model)
            }
        } else {
            hideMemoTooltip()
            tableView.reloadData()
        }
        if tooltip.isVisible, let hoveredRowID, let model = rows.first(where: { $0.id == hoveredRowID }), model.memo != tooltip.text {
            hideMemoTooltip()
        }
    }

    /// 行の表示（テスト用）。
    func rowView(at index: Int) -> TabRowView? {
        tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? TabRowView
    }

    // MARK: - テーブル

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = (tableView.makeView(withIdentifier: TabRowView.identifier, owner: self) as? TabRowView)
            ?? TabRowView(palette: palette)
        view.palette = palette
        view.delegate = self
        view.configure(rows[row])
        return view
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // MARK: - 並べ替え（spec: tab-operations「Reorder tabs by dragging」）

    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingSource is TabRowView, Self.sessionID(from: info) != nil else { return [] }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let id = Self.sessionID(from: info),
              let order = Self.reorderedIDs(rows.map(\.id), moving: id, toRow: row) else { return false }
        // ローカルの並びは変えず、デーモンの `sessions` を待つ（Web 版と同じ）。
        onReorder?(order)
        return true
    }

    private static func sessionID(from info: NSDraggingInfo) -> String? {
        info.draggingPasteboard.string(forType: .tabghosttySessionID)
    }

    /// `id` を、行 `row` の前（`row == ids.count` なら末尾）に動かした順序。動かないなら nil。
    nonisolated static func reorderedIDs(_ ids: [String], moving id: String, toRow row: Int) -> [String]? {
        guard let from = ids.firstIndex(of: id) else { return nil }
        var to = min(max(row, 0), ids.count)
        if to > from { to -= 1 }
        guard to != from else { return nil }
        var next = ids
        next.remove(at: from)
        next.insert(id, at: to)
        return next
    }

    // MARK: - 行の操作

    func tabRowClicked(_ row: TabRowView) {
        guard let id = row.model?.id else { return }
        onSelect?(id)
    }

    func tabRowDoubleClicked(_ row: TabRowView) {
        guard let id = row.model?.id else { return }
        hideMemoTooltip()
        onEditMemo?(id)
    }

    func tabRowWillBeginDrag(_ row: TabRowView) {
        hideMemoTooltip()
    }

    func tabRowMenu(_ row: TabRowView) -> NSMenu? {
        hideMemoTooltip()
        guard let id = row.model?.id, let session = sessions.first(where: { $0.id == id }) else { return nil }
        return TabContextMenu.makeMenu(for: session) { [weak self] action in
            self?.onMenuAction?(id, action)
        }
    }

    func tabRow(_ row: TabRowView, hoverChanged hovering: Bool) {
        guard let id = row.model?.id else { return }
        if hovering {
            hideMemoTooltip()
            hoveredRowID = id
            scheduleMemoTooltip(for: row, id: id)
        } else if hoveredRowID == id {
            hideMemoTooltip()
            hoveredRowID = nil
        }
    }

    // MARK: - メモのツールチップ（spec: tab-sidebar「Memo tooltip」）

    /// ツールチップを出しているか（テスト用）。
    var isMemoTooltipVisible: Bool { tooltip.isVisible }
    var memoTooltipText: String { tooltip.text }

    private func scheduleMemoTooltip(for row: TabRowView, id: String) {
        guard !isMemoEditorOpen, let memo = rows.first(where: { $0.id == id })?.memo, !memo.isEmpty else { return }
        let work = DispatchWorkItem { [weak self, weak row] in
            MainActor.assumeIsolated {
                guard let self, let row, self.hoveredRowID == id, row.model?.id == id, !self.isMemoEditorOpen,
                      let memo = self.rows.first(where: { $0.id == id })?.memo, !memo.isEmpty else { return }
                self.tooltipWork = nil
                self.tooltip.show(memo, beside: row, rowContentRect: row.bounds.insetBy(dx: TabRowView.horizontalInset, dy: 0))
            }
        }
        tooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.memoTooltipDelay, execute: work)
    }

    /// ツールチップを隠す（ポインタが離れた、メモの編集、ドラッグ、スクロール、ウィンドウの大きさの変更、メニュー）。
    public func hideMemoTooltip() {
        tooltipWork?.cancel()
        tooltipWork = nil
        tooltip.hide()
    }

    // MARK: - ボタン

    @objc private func collapse() {
        onCollapse?()
    }

    @objc private func newTab() {
        onNewTab?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}

/// サイドバーの背景（chrome トークンの sidebar 色）。
@MainActor
private final class SidebarBackgroundView: NSView {
    var color = ChromePalette.dark.sidebar {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        color.nsColor.setFill()
        dirtyRect.fill()
    }
}

/// 点線の枠のボタン（「＋ 新規タブ」。Web 版の `.new-tab`）。
@MainActor
final class DashedButton: NSButton {
    var palette = ChromePalette.dark {
        didSet { applyPalette() }
    }

    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        font = .systemFont(ofSize: 13)
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func applyPalette() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: palette.text.nsColor,
            .font: font ?? NSFont.systemFont(ofSize: 13),
        ])
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        (isHovered ? palette.accent : palette.border).nsColor.setStroke()
        path.stroke()
        super.draw(dirtyRect)
    }
}
