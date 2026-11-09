import AppKit
import DaemonClient

/// 設定画面のペインの共通部分（見出し・説明・エラーの表示と、縦に並べるレイアウト）。
@MainActor
class SettingsPaneController: NSViewController {
    let config: ConfigStore
    let editor: ConfigEditor
    /// ペインの中身を上から順に並べる。
    let stack = NSStackView()
    private var observations: [ConfigStore.Observation] = []

    init(config: ConfigStore, editor: ConfigEditor, title: String) {
        self.config = config
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        for observation in observations {
            config.removeObservation(observation)
        }
    }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        scroll.frame = NSRect(origin: .zero, size: SettingsWindowController.contentSize)
        view = scroll
        buildContent()
        refresh(from: config.settings)
    }

    /// 中身を作る（サブクラスで実装する）。
    func buildContent() {}

    // MARK: - テキストの欄

    /// 欄を編集しているか（テストで差し替える）。
    var isEditing: (NSTextField) -> Bool = { $0.currentEditor() != nil }
    /// 欄に最後に出した値（利用者が編集したかを見るのに使う）。
    private var shownValues: [ObjectIdentifier: String] = [:]

    /// 設定の値を欄に出す。編集中なら書き換えない（確定したときに、編集されていなければ新しい値を出す）。
    func show(_ value: String, in field: NSTextField) {
        guard !isEditing(field) else { return }
        setFieldValue(value, field)
    }

    /// 欄に値を書く（編集中でも書く）。
    func setFieldValue(_ value: String, _ field: NSTextField) {
        field.stringValue = value
        shownValues[ObjectIdentifier(field)] = value
    }

    /// 欄の文字列が、最後に出した値のままか（利用者が編集していない）。
    ///
    /// 編集している間に読み直しで設定が変わっても、欄は書き換えない。何も入力せずに確定したときは、
    /// 古い値を保存せず（ほかのクライアントでの変更を上書きしない）、新しい値を出す。
    func isUnedited(_ field: NSTextField, _ text: String) -> Bool {
        shownValues[ObjectIdentifier(field)] == text
    }

    /// 設定の値をコントロールに反映する（サブクラスで実装する）。
    func refresh(from settings: ClientSettings) {}

    /// `keys` が変わったら `refresh(from:)` を呼ぶ。
    func observe(_ keys: Set<ConfigKey>) {
        observations.append(config.observe(keys) { [weak self] settings, _ in
            guard let self, self.isViewLoaded else { return }
            self.refresh(from: settings)
        })
    }

    // MARK: - 部品

    func addHeading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        if !stack.arrangedSubviews.isEmpty {
            stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
        }
        stack.addArrangedSubview(label)
    }

    func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
        ).isActive = true
    }

    /// 説明文（折り返す、灰色）。
    func makeHint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        return label
    }

    /// エラーの表示（赤字。空なら隠す）。
    func makeErrorLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .systemRed
        label.isSelectable = true
        label.isHidden = true
        label.setAccessibilityRole(.staticText)
        return label
    }

    /// チェックボックスと、その下の説明。
    func makeCheckbox(_ title: String, hint: String?, action: Selector) -> (NSButton, NSView) {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
        guard let hint else { return (checkbox, checkbox) }
        // 説明はチェックボックスの文字の位置にそろえる。
        let indent = NSStackView(views: [makeHint(hint)])
        indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let column = NSStackView(views: [checkbox, indent])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return (checkbox, column)
    }
}

/// エラーの表示を変える。
@MainActor
func setError(_ label: NSTextField, _ message: String?) {
    label.stringValue = message ?? ""
    label.isHidden = message == nil
}

/// 上から下に並べるための、座標が反転したビュー（スクロールの先頭を上にする）。
@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 子のビューを左から右に並べ、幅を超えたら折り返す（通知するコマンドのチップ）。
@MainActor
final class FlowLayoutView: NSView {
    var spacing: CGFloat = 6
    private var arrangedHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    /// 並べるビューを差し替える。
    func setViews(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(arrangedHeight, height(forWidth: bounds.width)))
    }

    override func layout() {
        super.layout()
        let height = place(width: bounds.width)
        if abs(height - arrangedHeight) > 0.5 {
            arrangedHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    private func height(forWidth width: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.fittingSize
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return subviews.isEmpty ? 0 : y + rowHeight
    }

    @discardableResult
    private func place(width: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.fittingSize
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return subviews.isEmpty ? 0 : y + rowHeight
    }
}
