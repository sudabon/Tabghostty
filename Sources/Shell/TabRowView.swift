import AppKit

extension NSPasteboard.PasteboardType {
    /// サイドバーの並べ替えで運ぶセッション ID。
    static let tabghosttySessionID = NSPasteboard.PasteboardType("jp.sudabon.tabghostty.session-id")
}

/// 行の操作を受け取る（`SidebarViewController`）。
@MainActor
protocol TabRowViewDelegate: AnyObject {
    func tabRowClicked(_ row: TabRowView)
    func tabRowDoubleClicked(_ row: TabRowView)
    func tabRowWillBeginDrag(_ row: TabRowView)
    func tabRowMenu(_ row: TabRowView) -> NSMenu?
    func tabRow(_ row: TabRowView, hoverChanged hovering: Bool)
}

/// サイドバーの行 1 つ（spec: tab-sidebar「Three-row tab presentation」）。
///
/// 1 段目: 作業ディレクトリ、`◌`、未読ドット、状態 pill（右寄せ）。2 段目: コマンド。3 段目: 状態。
/// クリックで選択、ダブルクリックでメモの編集、6pt 動かすとドラッグ（並べ替え）、右クリックでメニュー。
@MainActor
final class TabRowView: NSView, NSDraggingSource {
    static let identifier = NSUserInterfaceItemIdentifier("TabRow")
    /// ドラッグとみなす移動量（spec: tab-operations「Reorder tabs by dragging」）。
    static let dragThreshold: CGFloat = 6
    /// 行の高さ（上下の余白 8pt と 3 段）。
    static let height: CGFloat = 62
    /// 行の左右の余白（Web 版のサイドバーの padding 6px）。
    static let horizontalInset: CGFloat = 6

    weak var delegate: TabRowViewDelegate?
    private(set) var model: TabRowModel?
    var palette: ChromePalette {
        didSet {
            pill.palette = palette
            applyModel()
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let noIntegrationLabel = NSTextField(labelWithString: "◌")
    private let unreadDot = NSView()
    private let pill: AgentStatePillView
    private let commandLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")

    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false
    private var mouseDownLocation: CGPoint?
    private(set) var isDragging = false

    init(palette: ChromePalette) {
        self.palette = palette
        pill = AgentStatePillView(palette: palette)
        super.init(frame: .zero)
        identifier = Self.identifier

        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        noIntegrationLabel.font = .systemFont(ofSize: 11)
        noIntegrationLabel.toolTip = "shell integration off"
        noIntegrationLabel.setAccessibilityLabel("shell integration off")
        noIntegrationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 3.5
        unreadDot.toolTip = "unread completion"
        unreadDot.setAccessibilityElement(true)
        unreadDot.setAccessibilityRole(.image)
        unreadDot.setAccessibilityLabel("unread completion")
        unreadDot.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let firstLine = NSStackView(views: [titleLabel, noIntegrationLabel, unreadDot, spacer, pill])
        firstLine.orientation = .horizontal
        firstLine.alignment = .centerY
        firstLine.spacing = 6
        firstLine.setHuggingPriority(.defaultLow, for: .horizontal)

        commandLabel.font = .systemFont(ofSize: 12)
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let lines = NSStackView(views: [firstLine, commandLabel, stateLabel])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 2
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        let inset = Self.horizontalInset + 10
        NSLayoutConstraint.activate([
            lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            firstLine.widthAnchor.constraint(equalTo: lines.widthAnchor),
            commandLabel.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor),
            stateLabel.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 7),
            unreadDot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 表示内容を変える。別のセッションの行に使い回すときは、ホバーとドラッグの状態を戻す。
    func configure(_ model: TabRowModel) {
        if self.model?.id != model.id {
            setHovered(false)
            mouseDownLocation = nil
        }
        self.model = model
        applyModel()
    }

    private func applyModel() {
        guard let model else { return }
        titleLabel.stringValue = model.title
        titleLabel.textColor = model.isExited ? palette.muted.nsColor : palette.text.nsColor
        noIntegrationLabel.isHidden = !model.showsNoIntegration
        noIntegrationLabel.textColor = palette.muted.nsColor
        unreadDot.isHidden = !model.isUnread
        unreadDot.layer?.backgroundColor = palette.accent.cgColor
        pill.model = model.pill

        commandLabel.stringValue = model.command
        commandLabel.toolTip = model.commandToolTip
        commandLabel.textColor = palette.text.nsColor
        commandLabel.alphaValue = model.isCommandDimmed ? 0.5 : 1

        stateLabel.stringValue = model.stateText
        switch model.stateStyle {
        case .running: stateLabel.textColor = palette.accent.nsColor
        case .error: stateLabel.textColor = palette.danger.nsColor
        case .muted: stateLabel.textColor = palette.muted.nsColor
        }
        setAccessibilityLabel([model.title, model.command, model.stateText, model.pill?.accessibilityLabel]
            .compactMap { $0 }.joined(separator: ", "))
        needsDisplay = true
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        let color: ChromeColor?
        if model.isActive {
            color = palette.active
        } else if isHovered {
            color = palette.hover
        } else {
            color = nil
        }
        guard let color else { return }
        color.nsColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.horizontalInset, dy: 0), xRadius: 6, yRadius: 6).fill()
    }

    // MARK: - ホバー（メモのツールチップ）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        needsDisplay = true
        delegate?.tabRow(self, hoverChanged: hovered)
    }

    // MARK: - クリック・ドラッグ・メニュー

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showContextMenu(with: event)
            return
        }
        isDragging = false
        if event.clickCount >= 2 {
            mouseDownLocation = nil
            delegate?.tabRowDoubleClicked(self)
            return
        }
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation, !isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard mouseDownLocation != nil, !isDragging else { return }
        delegate?.tabRowClicked(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        delegate?.tabRowMenu(self)
    }

    private func showContextMenu(with event: NSEvent) {
        guard let menu = delegate?.tabRowMenu(self) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func beginDrag(with event: NSEvent) {
        guard let model else { return }
        isDragging = true
        delegate?.tabRowWillBeginDrag(self)
        let item = NSPasteboardItem()
        item.setString(model.id, forType: .tabghosttySessionID)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshot() -> NSImage? {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownLocation = nil
    }
}
