import AppKit
import DaemonClient

/// 「キーボード」（spec: settings-window「Keyboard category」。webtabinal `KeyboardSettings.tsx` の移植）。
///
/// - Shift+Enter で改行する、ショートカットを有効にする。
/// - プレフィックス・次のタブ・前のタブ・サイドバー開閉の記録ボタン。押すと「キーを入力…」になり、次のキーを記録する
///   （Escape で取り消す）。検証に通らない割り当ては、メッセージを出して元に戻す。
/// - キー割り当てをリセット（有効かどうかはそのまま）。
@MainActor
final class KeyboardPaneController: SettingsPaneController {
    enum Slot: String, CaseIterable {
        case prefix
        case nextTab
        case prevTab
        case toggleSidebar

        var title: String {
            switch self {
            case .prefix: "プレフィックス"
            case .nextTab: "次のタブ"
            case .prevTab: "前のタブ"
            case .toggleSidebar: "サイドバー開閉"
            }
        }

        func value(in bindings: KeyBindings) -> String {
            switch self {
            case .prefix: bindings.prefix
            case .nextTab: bindings.nextTab
            case .prevTab: bindings.prevTab
            case .toggleSidebar: bindings.toggleSidebar
            }
        }

        func set(_ value: String, in bindings: inout KeyBindings) {
            switch self {
            case .prefix: bindings.prefix = value
            case .nextTab: bindings.nextTab = value
            case .prevTab: bindings.prevTab = value
            case .toggleSidebar: bindings.toggleSidebar = value
            }
        }
    }

    static let recordingTitle = "キーを入力…"

    let recorder = KeyRecorder()
    private(set) var shiftEnterCheckbox: NSButton!
    private(set) var shortcutsCheckbox: NSButton!
    private(set) var recorderButtons: [Slot: NSButton] = [:]
    let resetButton = NSButton(title: "キー割り当てをリセット", target: nil, action: nil)
    let shiftEnterError = NSTextField(wrappingLabelWithString: "")
    let bindingsError = NSTextField(wrappingLabelWithString: "")
    /// 記録しているボタン。
    private(set) var recordingSlot: Slot?
    /// アプリのキー入力を監視して記録する（テストでは false にして `recorder.handle` を直接呼ぶ）。
    var monitorKeyEvents = true
    private var shiftEnterInFlight = false
    private var bindingsInFlight = false

    init(config: ConfigStore, editor: ConfigEditor) {
        super.init(config: config, editor: editor, title: "キーボード")
        recorder.onRecord = { [weak self] spec in
            guard let self, let slot = self.recordingSlot else { return }
            self.recordingSlot = nil
            var next = self.config.committed.tabs.keyBindings
            slot.set(spec, in: &next)
            Task { await self.commit(next) }
        }
        recorder.onCancel = { [weak self] in
            self?.recordingSlot = nil
            self?.refreshButtons()
        }
    }

    override func buildContent() {
        addHeading("プロンプト入力")
        let (shiftEnter, shiftEnterRow) = makeCheckbox(
            "Shift+Enter で改行する", hint: "エージェントに送信せず改行を入れる", action: #selector(toggleShiftEnter(_:))
        )
        shiftEnter.setAccessibilityLabel("Shift+Enter で改行")
        shiftEnterCheckbox = shiftEnter
        addFullWidth(shiftEnterRow)
        for label in [shiftEnterError, bindingsError] {
            label.textColor = .systemRed
            label.isHidden = true
        }
        addFullWidth(shiftEnterError)

        addHeading("プレフィックスショートカット")
        let (shortcuts, shortcutsRow) = makeCheckbox(
            "ショートカットを有効にする",
            hint: "プレフィックスのあと、隣のタブへ移動したりサイドバーを開閉したりできます",
            action: #selector(toggleShortcuts(_:))
        )
        shortcuts.setAccessibilityLabel("タブ移動ショートカット")
        shortcutsCheckbox = shortcuts
        addFullWidth(shortcutsRow)

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 12
        for slot in Slot.allCases {
            let button = NSButton(title: "", target: self, action: #selector(recorderButtonClicked(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(slot.rawValue)
            button.setAccessibilityLabel(slot == .prefix ? "プレフィックスキー" : slot.title)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
            recorderButtons[slot] = button
            grid.addRow(with: [NSTextField(labelWithString: slot.title), button])
        }
        stack.addArrangedSubview(grid)
        addFullWidth(bindingsError)

        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(resetBindings(_:))
        stack.addArrangedSubview(resetButton)
        observe([.shiftEnterNewline, .keyBindings])
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelRecording()
    }

    override func refresh(from settings: ClientSettings) {
        shiftEnterCheckbox.state = settings.display.shiftEnterNewline ? .on : .off
        shortcutsCheckbox.state = settings.tabs.keyBindings.enabled ? .on : .off
        refreshButtons()
    }

    private func refreshButtons() {
        let bindings = config.settings.tabs.keyBindings
        for (slot, button) in recorderButtons {
            button.title = recordingSlot == slot ? Self.recordingTitle : Keymap.format(slot.value(in: bindings))
        }
    }

    /// ボタンに出している文字列（テスト用）。
    func buttonTitle(_ slot: Slot) -> String {
        recorderButtons[slot]?.title ?? ""
    }

    // MARK: - Shift+Enter

    @objc private func toggleShiftEnter(_ sender: NSButton) {
        let on = sender.state == .on
        Task { await setShiftEnterNewline(on) }
    }

    func setShiftEnterNewline(_ enabled: Bool) async {
        guard !shiftEnterInFlight else {
            refresh(from: config.settings)
            return
        }
        shiftEnterInFlight = true
        defer { shiftEnterInFlight = false }
        setError(shiftEnterError, nil)
        do {
            try await editor.apply(ConfigPatch(shiftEnterNewline: enabled))
        } catch {
            setError(shiftEnterError, ConfigEditor.message(for: error))
        }
    }

    // MARK: - キー割り当て

    @objc private func toggleShortcuts(_ sender: NSButton) {
        var next = config.committed.tabs.keyBindings
        next.enabled = sender.state == .on
        Task { await commit(next) }
    }

    @objc private func recorderButtonClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let slot = Slot(rawValue: raw) else { return }
        startRecording(slot)
    }

    /// 記録を始める（「キーを入力…」を出し、次のキーを待つ）。
    func startRecording(_ slot: Slot) {
        setError(bindingsError, nil)
        recordingSlot = slot
        recorder.start(monitorEvents: monitorKeyEvents)
        refreshButtons()
    }

    func cancelRecording() {
        guard recordingSlot != nil else { return }
        recordingSlot = nil
        recorder.stop()
        refreshButtons()
    }

    @objc private func resetBindings(_ sender: NSButton) {
        Task { await commit(SettingsRules.resetBindings(keepingEnabledFrom: config.committed.tabs.keyBindings)) }
    }

    /// 割り当てを保存する。検証に通らなければメッセージを出して元に戻す。変わっていなければ何もしない。
    func commit(_ next: KeyBindings) async {
        let persisted = config.committed.tabs.keyBindings
        if let issue = Keymap.validate(next) {
            setError(bindingsError, SettingsRules.message(for: issue))
            refresh(from: config.settings)
            return
        }
        guard next != persisted else {
            setError(bindingsError, nil)
            refresh(from: config.settings)
            return
        }
        guard !bindingsInFlight else {
            refresh(from: config.settings)
            return
        }
        bindingsInFlight = true
        defer { bindingsInFlight = false }
        setError(bindingsError, nil)
        do {
            try await editor.apply(ConfigPatch(keyBindings: next))
        } catch {
            setError(bindingsError, ConfigEditor.message(for: error))
        }
        refresh(from: config.settings)
    }
}
