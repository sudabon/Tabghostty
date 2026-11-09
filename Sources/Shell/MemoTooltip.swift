import AppKit

/// タブメモのツールチップ（spec: tab-sidebar「Memo tooltip」）。
///
/// 標準の `toolTip` では表示までの時間と隠す操作を決められないので、ウィンドウの中に重ねる独自のビューにする
/// （phase3 design D2）。表示する時間と隠す条件は `SidebarViewController` が決める。
@MainActor
final class MemoTooltip {
    static let maxWidth: CGFloat = 220
    /// 行の右端からの間隔（Web 版の `rect.right + 8`）。
    static let gap: CGFloat = 8

    var palette: ChromePalette {
        didSet { view.applyColors(palette) }
    }

    private let view: MemoTooltipView

    init(palette: ChromePalette) {
        self.palette = palette
        view = MemoTooltipView(palette: palette)
    }

    var isVisible: Bool { view.superview != nil }
    var text: String { view.text }

    /// 行の右に出す。
    /// - Parameter rowContentRect: 行の中で、背景を塗る部分（行の座標）
    func show(_ text: String, beside row: NSView, rowContentRect: NSRect) {
        guard let host = row.window?.contentView else { return }
        view.text = text
        let size = view.fittingSize
        let anchor = row.convert(rowContentRect, to: host)
        var origin = CGPoint(x: anchor.maxX + Self.gap, y: host.isFlipped ? anchor.minY : anchor.maxY - size.height)
        origin.x = min(origin.x, max(0, host.bounds.width - size.width))
        origin.y = min(max(0, origin.y), max(0, host.bounds.height - size.height))
        view.frame = NSRect(origin: origin, size: size)
        if view.superview !== host {
            view.removeFromSuperview()
            host.addSubview(view, positioned: .above, relativeTo: nil)
        }
    }

    func hide() {
        view.removeFromSuperview()
    }
}

@MainActor
private final class MemoTooltipView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let padding = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

    init(palette: ChromePalette) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = false
        label.preferredMaxLayoutWidth = MemoTooltip.maxWidth - padding.left - padding.right
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            label.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding.bottom),
            widthAnchor.constraint(lessThanOrEqualToConstant: MemoTooltip.maxWidth),
        ])
        setAccessibilityRole(.helpTag)
        applyColors(palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
        }
    }

    func applyColors(_ palette: ChromePalette) {
        layer?.backgroundColor = palette.background.cgColor
        layer?.borderColor = palette.border.cgColor
        layer?.shadowColor = palette.shadow.cgColor
        label.textColor = palette.text.nsColor
    }

    /// クリックを下のビューに通す（Web 版の `pointer-events: none`）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
