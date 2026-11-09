import AppKit
import DaemonClient
import DesktopSupport

/// 「通知」（spec: settings-window「Notifications category」、notifications「User-initiated authorization」。
/// webtabinal `NotificationsSettings.tsx` の移植）。
///
/// - 変更はすぐに保存する。保存している間は、このカテゴリのコントロールをすべて無効にする（保存中のロック）。
/// - 状態検出が無効なら、blocked とプロンプト復帰の通知、詳細設定を無効にする。
/// - 通知の許可の状態を出し、未決定のときだけ「通知を許可」を出す。開いたときと、アプリが前面に来たときに更新する。
@MainActor
final class NotificationsPaneController: SettingsPaneController, NSTextFieldDelegate {
    /// 許可の状態ごとの文言。
    static func permissionCopy(_ permission: DesktopNotificationPermission) -> (label: String, guidance: String) {
        switch permission {
        case .default:
            ("システム通知の許可が必要です", "下のボタンを押すと、macOS の通知の許可を確認します。")
        case .granted:
            ("システム通知は許可されています", "Tabghostty からの通知を受け取れます。")
        case .denied:
            ("システム通知は許可されていません",
             "macOS の「システム設定 > 通知」で Tabghostty を許可してください。通知が出なくても、タブの未読と Dock のバッジは付きます。")
        case .unsupported:
            ("この環境ではシステム通知を利用できません", "通知を使うには、`make app` で作った Tabghostty.app として起動してください。")
        }
    }

    private let service: any NativeNotificationServicing

    private(set) var enabledCheckbox: NSButton!
    private(set) var alwaysCheckbox: NSButton!
    let commandList = FlowLayoutView()
    let commandField = NSTextField()
    let addCommandButton = NSButton(title: "追加", target: nil, action: nil)
    private(set) var stateEnabledCheckbox: NSButton!
    private(set) var notifyBlockedCheckbox: NSButton!
    private(set) var notifyIdleCheckbox: NSButton!
    let advancedButton = NSButton(title: "詳細設定", target: nil, action: nil)
    let advancedBox = NSStackView()
    let debounceField = NSTextField()
    let quiescenceField = NSTextField()
    let bottomLinesField = NSTextField()
    let manifestDirField = NSTextField()
    let permissionLabel = NSTextField(labelWithString: "")
    let permissionGuidance = NSTextField(wrappingLabelWithString: "")
    let permissionButton = NSButton(title: "通知を許可", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")

    /// 表示している許可の状態。
    private(set) var permission: DesktopNotificationPermission = .default
    /// 保存中（このカテゴリのコントロールを無効にする）。
    private(set) var isSaving = false {
        didSet { updateEnabledStates() }
    }
    private var isRequestingPermission = false

    init(config: ConfigStore, editor: ConfigEditor, service: any NativeNotificationServicing) {
        self.service = service
        super.init(config: config, editor: editor, title: "通知")
    }

    override func buildContent() {
        addHeading("アプリ内の通知設定")
        let (enabled, enabledRow) = makeCheckbox("通知を有効にする", hint: "完了・入力待ちを通知", action: #selector(toggleNotificationFlag(_:)))
        let (always, alwaysRow) = makeCheckbox("操作中も通知する", hint: "前面のアクティブタブも対象", action: #selector(toggleNotificationFlag(_:)))
        enabledCheckbox = enabled
        alwaysCheckbox = always
        addFullWidth(enabledRow)
        addFullWidth(alwaysRow)

        addHeading("通知するコマンド")
        addFullWidth(makeHint(
            "ここに挙げたコマンドのセッションだけが通知を出します（完了・入力待ち・ターン完了のすべて）。"
                + "一覧が空のときはすべてのセッションが通知します。通知を全部止めるときは「通知を有効にする」をオフにしてください。"
                + "一覧から外れたセッションもタブの未読ドットは付きます。"
        ))
        addFullWidth(commandList)
        commandField.placeholderString = "コマンド名（例: make）"
        commandField.delegate = self
        commandField.isAutomaticTextCompletionEnabled = false
        commandField.target = self
        commandField.action = #selector(submitCommand(_:))
        addCommandButton.target = self
        addCommandButton.action = #selector(submitCommand(_:))
        addCommandButton.bezelStyle = .rounded
        let addRow = NSStackView(views: [commandField, addCommandButton])
        addRow.spacing = 8
        commandField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        stack.addArrangedSubview(addRow)

        addHeading("エージェント状態")
        let (stateEnabled, stateRow) = makeCheckbox(
            "状態検出を有効にする", hint: "画面から idle / working / blocked を表示", action: #selector(toggleStateFlag(_:))
        )
        let (blocked, blockedRow) = makeCheckbox(
            "blocked を通知する", hint: "入力待ちへの遷移を通知。OSC 通知は維持", action: #selector(toggleStateFlag(_:))
        )
        let (idle, idleRow) = makeCheckbox(
            "画面検知でプロンプト復帰を通知する",
            hint: "hook を設定していないエージェント向け。画面の静止で判定するため、思考中の一時停止でも通知されます",
            action: #selector(toggleStateFlag(_:))
        )
        stateEnabledCheckbox = stateEnabled
        notifyBlockedCheckbox = blocked
        notifyIdleCheckbox = idle
        addFullWidth(stateRow)
        addFullWidth(blockedRow)
        addFullWidth(idleRow)

        advancedButton.bezelStyle = .disclosure
        advancedButton.setButtonType(.pushOnPushOff)
        advancedButton.title = ""
        advancedButton.target = self
        advancedButton.action = #selector(toggleAdvanced(_:))
        let advancedLabel = NSTextField(labelWithString: "詳細設定")
        let advancedRow = NSStackView(views: [advancedButton, advancedLabel])
        advancedRow.spacing = 4
        stack.addArrangedSubview(advancedRow)
        buildAdvanced()
        addFullWidth(advancedBox)
        advancedBox.isHidden = true

        addHeading("システムの通知許可")
        permissionLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        permissionGuidance.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        permissionGuidance.textColor = .secondaryLabelColor
        stack.addArrangedSubview(permissionLabel)
        addFullWidth(permissionGuidance)
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(requestPermissionClicked(_:))
        stack.addArrangedSubview(permissionButton)
        applyPermission(.default)

        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        addFullWidth(errorLabel)

        observe([
            .notificationEnabled, .notificationAlways, .notificationCommands,
            .stateEnabled, .stateNotifyOnBlocked, .stateNotifyOnIdle,
            .stateDebounceMs, .stateQuiescenceMs, .stateBottomLines, .stateManifestDir,
        ])
    }

    private func buildAdvanced() {
        advancedBox.orientation = .vertical
        advancedBox.alignment = .leading
        advancedBox.spacing = 6
        advancedBox.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let rows: [(String, NSTextField, String)] = [
            ("デバウンス (ms)", debounceField, "20–5000。画面評価の最短間隔"),
            ("静止時間 (ms)", quiescenceField, "0–60000。マニフェスト指定があればそちらが優先されます"),
            ("判定する末尾行数", bottomLinesField, "1–200。マニフェスト指定があればそちらが優先されます"),
            ("マニフェストディレクトリ", manifestDirField, "空欄は Application Support の既定ディレクトリを使います。変更はデーモン再起動後に読み込まれます"),
        ]
        for (title, field, hint) in rows {
            field.delegate = self
            field.isAutomaticTextCompletionEnabled = false
            field.setAccessibilityLabel(title)
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 170).isActive = true
            let row = NSStackView(views: [label, field])
            row.spacing = 8
            field.widthAnchor.constraint(equalToConstant: field === manifestDirField ? 240 : 100).isActive = true
            advancedBox.addArrangedSubview(row)
            advancedBox.addArrangedSubview(makeHint(hint))
        }
    }

    override func refresh(from settings: ClientSettings) {
        let notification = settings.tabs.notification
        enabledCheckbox.state = notification.enabled ? .on : .off
        alwaysCheckbox.state = notification.always ? .on : .off
        refreshCommands(notification.commands)
        let state = settings.state
        stateEnabledCheckbox.state = state.enabled ? .on : .off
        notifyBlockedCheckbox.state = state.notifyOnBlocked ? .on : .off
        notifyIdleCheckbox.state = state.notifyOnIdle ? .on : .off
        for field in [debounceField, quiescenceField, bottomLinesField, manifestDirField] {
            show(Self.text(of: field, in: state, pane: self), in: field)
        }
        updateEnabledStates()
    }

    /// 一覧に出しているコマンド（テスト用）。
    private(set) var listedCommands: [String] = []

    private func refreshCommands(_ commands: [String]) {
        listedCommands = commands
        if commands.isEmpty {
            let empty = NSTextField(labelWithString: "すべてのセッションが通知します")
            empty.textColor = .secondaryLabelColor
            commandList.setViews([empty])
            return
        }
        commandList.setViews(commands.map { name in
            let chip = NSButton(title: "\(name)  ×", target: self, action: #selector(removeCommandClicked(_:)))
            chip.bezelStyle = .inline
            chip.identifier = NSUserInterfaceItemIdentifier(name)
            chip.setAccessibilityLabel("\(name) を通知するコマンドから外す")
            chip.isEnabled = !isSaving
            return chip
        })
    }

    private func updateEnabledStates() {
        guard isViewLoaded else { return }
        let detectionOn = config.settings.state.enabled
        let dependentsEnabled = !isSaving && detectionOn
        enabledCheckbox.isEnabled = !isSaving
        alwaysCheckbox.isEnabled = !isSaving
        commandField.isEnabled = !isSaving
        addCommandButton.isEnabled = !isSaving
        for chip in commandList.subviews.compactMap({ $0 as? NSButton }) {
            chip.isEnabled = !isSaving
        }
        stateEnabledCheckbox.isEnabled = !isSaving
        notifyBlockedCheckbox.isEnabled = dependentsEnabled
        notifyIdleCheckbox.isEnabled = dependentsEnabled
        for field in [debounceField, quiescenceField, bottomLinesField, manifestDirField] {
            field.isEnabled = dependentsEnabled
        }
        permissionButton.isEnabled = !isRequestingPermission
    }

    // MARK: - 保存（保存中のロック）

    /// 変更を保存する。保存中ならなにもしない（コントロールは無効になっている）。保存できたら true。
    @discardableResult
    func save(_ patch: ConfigPatch) async -> Bool {
        guard !isSaving else {
            refresh(from: config.settings)
            return false
        }
        isSaving = true
        setError(errorLabel, nil)
        defer { isSaving = false }
        do {
            try await editor.apply(patch)
            return true
        } catch {
            setError(errorLabel, ConfigEditor.message(for: error))
            return false
        }
    }

    @objc private func toggleNotificationFlag(_ sender: NSButton) {
        let on = sender.state == .on
        let patch = sender === enabledCheckbox
            ? ConfigPatch(notification: .init(enabled: on))
            : ConfigPatch(notification: .init(always: on))
        Task { await save(patch) }
    }

    @objc private func toggleStateFlag(_ sender: NSButton) {
        let on = sender.state == .on
        let patch: ConfigPatch
        switch sender {
        case stateEnabledCheckbox: patch = ConfigPatch(state: .init(enabled: on))
        case notifyBlockedCheckbox: patch = ConfigPatch(state: .init(notifyOnBlocked: on))
        default: patch = ConfigPatch(state: .init(notifyOnIdle: on))
        }
        Task { await save(patch) }
    }

    // MARK: - 通知するコマンド

    @objc private func submitCommand(_ sender: Any?) {
        Task { await addCommand(commandField.stringValue) }
    }

    /// コマンドを追加する。前後の空白を削り、空か、大文字小文字を区別せずに同じものがあれば何もしない。
    func addCommand(_ draft: String) async {
        guard !isSaving,
              let next = SettingsRules.addingCommand(draft, to: config.settings.tabs.notification.commands) else { return }
        // 保存できたら欄を空にする（失敗したら、入力したコマンドを残す）。
        if await save(ConfigPatch(notification: .init(commands: next))) {
            commandField.stringValue = ""
        }
    }

    @objc private func removeCommandClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        Task { await removeCommand(name) }
    }

    func removeCommand(_ name: String) async {
        let next = SettingsRules.removingCommand(name, from: config.settings.tabs.notification.commands)
        await save(ConfigPatch(notification: .init(commands: next)))
    }

    // MARK: - 詳細設定（フォーカスを失ったときに確定する）

    @objc private func toggleAdvanced(_ sender: NSButton) {
        setAdvancedVisible(advancedBox.isHidden)
    }

    func setAdvancedVisible(_ visible: Bool) {
        advancedBox.isHidden = !visible
        advancedButton.state = visible ? .on : .off
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== commandField else { return }
        let text = field.stringValue
        Task { await commitAdvanced(field, text) }
    }

    /// 詳細設定の欄を確定する。数値でないか変わっていなければ戻す。デーモンに拒否されたら戻してエラーを出す。
    func commitAdvanced(_ field: NSTextField, _ text: String) async {
        // 何も入力していなければ保存しない（編集中にほかのクライアントで変わった値を、古い値で上書きしない）。
        if isUnedited(field, text) {
            setFieldValue(Self.text(of: field, in: config.settings.state, pane: self), field)
            return
        }
        let state = config.committed.state
        let patch: ConfigPatch?
        switch field {
        case debounceField:
            patch = SettingsRules.numberCommit(text, persisted: state.debounceMs).map { ConfigPatch(state: .init(debounceMs: $0)) }
        case quiescenceField:
            patch = SettingsRules.numberCommit(text, persisted: state.quiescenceMs).map { ConfigPatch(state: .init(quiescenceMs: $0)) }
        case bottomLinesField:
            patch = SettingsRules.numberCommit(text, persisted: state.bottomLines).map { ConfigPatch(state: .init(bottomLines: $0)) }
        case manifestDirField:
            if case .save(let dir) = SettingsRules.manifestDirCommit(text, persisted: state.manifestDir) {
                patch = ConfigPatch(state: .init(manifestDir: dir))
            } else {
                patch = nil
            }
        default:
            return
        }
        if let patch {
            await save(patch)
        }
        // 確定した値（戻したとき・失敗したときは保存済みの値）を出す。Enter で確定した欄は編集中のままなので、直接書く。
        setFieldValue(Self.text(of: field, in: config.settings.state, pane: self), field)
        refresh(from: config.settings)
    }

    private static func text(of field: NSTextField, in state: StateSettings, pane: NotificationsPaneController) -> String {
        switch field {
        case pane.debounceField: String(state.debounceMs)
        case pane.quiescenceField: String(state.quiescenceMs)
        case pane.bottomLinesField: String(state.bottomLines)
        default: state.manifestDir
        }
    }

    // MARK: - 通知の許可

    /// 許可の状態を読み直す（開いたとき、アプリが前面に来たとき）。
    func refreshPermission() async {
        applyPermission(await service.permission())
    }

    @objc private func requestPermissionClicked(_ sender: NSButton) {
        Task { await requestPermission() }
    }

    /// 許可を求める（利用者がボタンを押したときだけ）。
    func requestPermission() async {
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        permissionButton.title = "確認中…"
        updateEnabledStates()
        setError(errorLabel, nil)
        defer {
            isRequestingPermission = false
            permissionButton.title = "通知を許可"
            updateEnabledStates()
        }
        do {
            applyPermission(try await service.requestPermission())
        } catch {
            setError(errorLabel, error.localizedDescription)
        }
    }

    private func applyPermission(_ permission: DesktopNotificationPermission) {
        self.permission = permission
        let copy = Self.permissionCopy(permission)
        permissionLabel.stringValue = copy.label
        permissionGuidance.stringValue = copy.guidance
        // 許可を求めるボタンは、未決定のときだけ出す。
        permissionButton.isHidden = permission != .default
    }
}
