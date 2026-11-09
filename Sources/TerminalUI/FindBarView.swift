import AppKit
import TerminalCore

/// 端末の上に重ねる検索バー（spec: terminal-search「Find bar」、phase5 design D5）。
///
/// - 検索欄に入力すると、そのたびに `onQueryChange` を呼ぶ（端末には送らない。欄が first responder なので、
///   キーは欄に届き、`TerminalView.keyDown` には届かない）。
/// - Enter で次、Shift+Enter で前、Escape か閉じるボタンで閉じる。
/// - 件数は `n / m`（一致が無ければ `0 / 0`）。
@MainActor
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let countLabel = NSTextField(labelWithString: SearchStatus.empty.label)
    let previousButton = NSButton()
    let nextButton = NSButton()
    let closeButton = NSButton()

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    /// 今のキーの修飾キー（Shift+Enter を見分ける。Enter と同じ `insertNewline:` が届くため）。テストで差し替える。
    var currentModifierFlags: () -> NSEvent.ModifierFlags = { NSApplication.shared.currentEvent?.modifierFlags ?? [] }

    /// 表示している件数。
    var status = SearchStatus.empty {
        didSet { countLabel.stringValue = status.label }
    }

    var query: String { field.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("検索")

        field.placeholderString = "検索"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = self
        field.focusRingType = .none
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.setAccessibilityLabel("検索する文字列")

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setAccessibilityLabel("一致した数")

        configure(previousButton, symbol: "chevron.up", label: "前を検索（Shift+Enter / Command-Shift-G）", action: #selector(previous))
        configure(nextButton, symbol: "chevron.down", label: "次を検索（Enter / Command-G）", action: #selector(next))
        configure(closeButton, symbol: "xmark", label: "検索バーを閉じる（Escape）", action: #selector(close))

        let stack = NSStackView(views: [field, countLabel, previousButton, nextButton, closeButton])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.refusesFirstResponder = true
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }

    /// 検索欄にフォーカスを移し、入力済みの文字列を選ぶ（続けて打つと置き換わる）。
    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// 検索欄（またはその編集中のフィールドエディタ）にフォーカスがあるか。
    var hasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === field { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, editor.delegate as? NSSearchField === field { return true }
        return false
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        onQueryChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            if currentModifierFlags().contains(.shift) {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    @objc private func previous() { onPrevious?() }
    @objc private func next() { onNext?() }
    @objc private func close() { onClose?() }
}
