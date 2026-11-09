import AppKit
import DaemonClient

/// 「外観」（spec: settings-window「Appearance category」、color-scheme）。テーマを選ぶと、すぐに保存して切り替える。
/// 素早く切り替えたときの競合は `ConfigEditor` が扱う（古い応答で巻き戻さない）。
@MainActor
final class AppearancePaneController: SettingsPaneController {
    static let options: [(scheme: ColorSchemeSetting, title: String, hint: String)] = [
        (.light, "ライト", "常に明るいテーマ"),
        (.dark, "ダーク", "常に暗いテーマ"),
        (.system, "自動", "OS の設定に合わせる"),
    ]

    private(set) var radios: [ColorSchemeSetting: NSButton] = [:]
    let errorLabel: NSTextField

    init(config: ConfigStore, editor: ConfigEditor) {
        errorLabel = NSTextField(wrappingLabelWithString: "")
        super.init(config: config, editor: editor, title: "外観")
    }

    override func buildContent() {
        addHeading("テーマ")
        for option in Self.options {
            let radio = NSButton(radioButtonWithTitle: option.title, target: self, action: #selector(chooseScheme(_:)))
            radio.identifier = NSUserInterfaceItemIdentifier(option.scheme.rawValue)
            radios[option.scheme] = radio
            let hint = makeHint(option.hint)
            let row = NSStackView(views: [radio, hint])
            row.spacing = 12
            row.alignment = .firstBaseline
            stack.addArrangedSubview(row)
        }
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        addFullWidth(errorLabel)
        observe([.colorScheme])
    }

    override func refresh(from settings: ClientSettings) {
        for (scheme, radio) in radios {
            radio.state = scheme == settings.display.colorScheme ? .on : .off
        }
    }

    @objc private func chooseScheme(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let scheme = ColorSchemeSetting(rawValue: raw) else { return }
        Task { await choose(scheme) }
    }

    /// テーマを選ぶ（保存が終わるまで待つ）。
    func choose(_ scheme: ColorSchemeSetting) async {
        setError(errorLabel, nil)
        do {
            try await editor.apply(ConfigPatch(colorScheme: scheme))
        } catch {
            setError(errorLabel, ConfigEditor.message(for: error))
        }
    }
}

/// 「一般」（spec: settings-window「General category」）。起動シェルとセッションの復元。
@MainActor
final class GeneralPaneController: SettingsPaneController, NSTextFieldDelegate {
    let shellField = NSTextField()
    private(set) var restoreCheckbox: NSButton!
    let shellError: NSTextField
    let restoreError: NSTextField
    private var shellInFlight = false
    /// 保存している間に確定した起動シェル（保存が終わってから保存する）。
    private var pendingShellText: String?
    private var restoreInFlight = false

    init(config: ConfigStore, editor: ConfigEditor) {
        shellError = NSTextField(wrappingLabelWithString: "")
        restoreError = NSTextField(wrappingLabelWithString: "")
        super.init(config: config, editor: editor, title: "一般")
    }

    override func buildContent() {
        addHeading("起動シェル")
        shellField.placeholderString = "/bin/zsh または /bin/bash"
        shellField.setAccessibilityLabel("起動シェル")
        shellField.delegate = self
        shellField.isAutomaticTextCompletionEnabled = false
        addFullWidth(shellField)
        addFullWidth(makeHint("zsh / bash ではサイドバーのカレントディレクトリとコマンドがライブ更新されます。新しいタブから適用されます"))
        for label in [shellError, restoreError] {
            label.textColor = .systemRed
            label.isHidden = true
        }
        addFullWidth(shellError)

        addHeading("セッションの復元")
        let (checkbox, row) = makeCheckbox(
            "エージェントセッションを復元する",
            hint: "復元したタブでは resume コマンド（claude --continue など）が自動実行されます",
            action: #selector(toggleRestore(_:))
        )
        checkbox.setAccessibilityLabel("エージェントセッションを復元")
        restoreCheckbox = checkbox
        addFullWidth(row)
        addFullWidth(restoreError)
        addFullWidth(makeHint(
            "デーモンの停止時に開いていたエージェントのタブを、次回の起動でカレントディレクトリとメモごと開き直します。"
                + "エージェントごとの resume コマンドの変更は config.json の restore.commands で行います"
        ))
        observe([.shell, .restoreEnabled])
    }

    override func refresh(from settings: ClientSettings) {
        // 入力中の欄は書き換えない（確定したときに、編集されていなければ新しい値を出す）。
        show(settings.general.shell, in: shellField)
        restoreCheckbox.state = settings.general.restoreEnabled ? .on : .off
    }

    // MARK: - 起動シェル（フォーカスを失ったときか Enter で確定する。変換中の Enter は確定しない）

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === shellField else { return }
        Task { await commitShell(shellField.stringValue) }
    }

    /// 起動シェルを確定する。前後の空白を削り、空か変わっていなければ戻す。デーモンに拒否されたら戻してエラーを出す。
    /// 保存している間に確定したら、保存が終わってから保存する。
    func commitShell(_ text: String) async {
        // 何も入力していなければ保存しない（編集中にほかのクライアントで変わった値を、古い値で上書きしない）。
        if isUnedited(shellField, text) {
            setFieldValue(config.settings.general.shell, shellField)
            return
        }
        let persisted = config.committed.general.shell
        switch SettingsRules.shellCommit(text, persisted: persisted) {
        case .revert:
            setFieldValue(persisted, shellField)
        case .save(let shell):
            guard !shellInFlight else {
                pendingShellText = text
                return
            }
            shellInFlight = true
            setError(shellError, nil)
            do {
                try await editor.apply(ConfigPatch(shell: shell))
            } catch {
                setError(shellError, ConfigEditor.message(for: error))
            }
            shellInFlight = false
            if let pending = pendingShellText {
                pendingShellText = nil
                await commitShell(pending)
                return
            }
            setFieldValue(config.settings.general.shell, shellField)
        }
    }

    // MARK: - セッションの復元

    @objc private func toggleRestore(_ sender: NSButton) {
        let enabled = sender.state == .on
        Task { await setRestoreEnabled(enabled) }
    }

    func setRestoreEnabled(_ enabled: Bool) async {
        guard !restoreInFlight else {
            refresh(from: config.settings)
            return
        }
        restoreInFlight = true
        defer { restoreInFlight = false }
        setError(restoreError, nil)
        do {
            try await editor.apply(ConfigPatch(restore: .init(enabled: enabled)))
        } catch {
            setError(restoreError, ConfigEditor.message(for: error))
        }
    }
}
