import AppKit

/// タブメモの編集シート（spec: tab-operations「Edit a tab memo」、phase3 design D5）。
///
/// - 30 code point に収める（IME で変換中は収めない）。
/// - Enter（変換中でないとき）か「保存」で、前後の空白を削った値を保存する。空ならメモを消す。
/// - Escape か「キャンセル」で、保存せずに閉じる。
/// - 保存に失敗したら、シートを開いたままエラーを出す。
@MainActor
public final class MemoEditorSheet: NSWindowController, NSTextFieldDelegate {
    public typealias Save = @MainActor (String) async throws -> Void

    private let save: Save
    private let field = NSTextField()
    /// 最後に受け付けた値（上限を超えたら、ここから増えた分だけを削る）。
    private var acceptedText = ""
    private let remainingLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let cancelButton = NSButton(title: "キャンセル", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    private var completion: (() -> Void)?
    public private(set) var isSaving = false

    public init(initialMemo: String, palette: ChromePalette, save: @escaping Save) {
        self.save = save
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "タブメモ"
        panel.appearance = palette.appearance
        super.init(window: panel)
        buildContent(in: panel)
        field.stringValue = MemoText.clamp(initialMemo)
        acceptedText = field.stringValue
        updateRemaining()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildContent(in panel: NSPanel) {
        let title = NSTextField(labelWithString: "タブメモ")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        remainingLabel.textColor = .secondaryLabelColor
        remainingLabel.font = .systemFont(ofSize: 12)
        remainingLabel.alignment = .right
        let header = NSStackView(views: [title, NSView(), remainingLabel])
        header.orientation = .horizontal

        field.placeholderString = "用途を短くメモ（任意）"
        field.delegate = self
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("タブメモ")

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true
        errorLabel.preferredMaxLayoutWidth = 320

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveMemo(_:))
        saveButton.bezelStyle = .rounded
        // Return を既定のボタンに割り当てない（IME で確定する Enter で保存しないよう、Enter はフィールドで受ける）。
        let footer = NSStackView(views: [NSView(), cancelButton, saveButton])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [header, field, errorLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            content.widthAnchor.constraint(equalToConstant: 360),
        ])
        panel.contentView = content
        panel.initialFirstResponder = field
    }

    // MARK: - 開く・閉じる

    /// ウィンドウのシートとして開く。閉じたら `completion` を呼ぶ。
    public func begin(for parent: NSWindow, completion: @escaping () -> Void) {
        guard let window else { return }
        self.completion = completion
        parent.beginSheet(window) { _ in }
        window.makeFirstResponder(field)
    }

    private func close(saved: Bool) {
        guard let window else { return }
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        let completion = self.completion
        self.completion = nil
        completion?()
    }

    // MARK: - 入力（spec: 30 code point、変換中は収めない）

    /// 今の値（テスト用）。
    public var text: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            textDidChange()
        }
    }

    /// 「残り N」（テスト用）。
    public var remainingText: String { remainingLabel.stringValue }
    /// 表示中のエラー（テスト用）。表示していなければ nil。
    public var errorText: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }

    public func controlTextDidChange(_ notification: Notification) {
        textDidChange()
    }

    private func textDidChange() {
        let editor = field.currentEditor() as? NSTextView
        let composing = editor?.hasMarkedText() ?? false
        if !composing {
            // 31 文字目からは受け付けない。入力・ペーストした分の後ろを削り、もとの文字とカーソルの位置は残す。
            let caret = editor.map { $0.selectedRange().location }
            if let fitted = MemoText.fit(field.stringValue, previous: acceptedText, caret: caret) {
                field.stringValue = fitted.text
                field.currentEditor()?.selectedRange = NSRange(location: fitted.caret, length: 0)
            }
            acceptedText = field.stringValue
        }
        updateRemaining()
    }

    private func updateRemaining() {
        remainingLabel.stringValue = "残り \(MemoText.remaining(field.stringValue))"
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // 変換中の Enter と Escape は IME が受けるので、ここには来ない。
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            saveMemo(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(nil)
            return true
        default:
            return false
        }
    }

    // MARK: - 保存

    /// フィールドの外で Escape を押した。
    public override func cancelOperation(_ sender: Any?) {
        cancel(sender)
    }

    @objc func cancel(_ sender: Any?) {
        guard !isSaving else { return }
        close(saved: false)
    }

    @objc func saveMemo(_ sender: Any?) {
        guard !isSaving else { return }
        let value = MemoText.normalizedForSave(MemoText.clamp(field.stringValue))
        setSaving(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.save(value)
                self.setSaving(false)
                self.close(saved: true)
            } catch {
                self.setSaving(false)
                self.errorLabel.stringValue = error.localizedDescription
                self.errorLabel.isHidden = false
                self.window?.makeFirstResponder(self.field)
            }
        }
    }

    private func setSaving(_ saving: Bool) {
        isSaving = saving
        field.isEnabled = !saving
        cancelButton.isEnabled = !saving
        saveButton.isEnabled = !saving
    }
}
