import AppKit
import DaemonClient
import DesktopSupport
import Testing
import TerminalCore
import TerminalUI
@testable import Shell

/// 設定画面と、その下の `ConfigStore` / `ConfigEditor`。
@MainActor
struct SettingsHarness {
    let api = FakeConfigAPI()
    let config: ConfigStore
    let editor: ConfigEditor
    let notifier = FakeNotificationService()
    let window: SettingsWindowController

    init(_ settings: ClientSettings = ClientSettings()) {
        api.server = settings
        config = ConfigStore(settings: settings, api: api)
        editor = ConfigEditor(store: config, api: api)
        window = SettingsWindowController(config: config, editor: editor, notifications: notifier, theme: .dark)
        for pane in [window.appearancePane, window.generalPane, window.notificationsPane, window.keyboardPane] as [NSViewController] {
            pane.loadViewIfNeeded()
        }
        window.keyboardPane.monitorKeyEvents = false
    }
}

private func click(_ button: NSButton) {
    button.performClick(nil)
}

/// spec: settings-window「Settings window layout」「Appearance category」「General category」（tasks 4.1 / 4.2）。
@MainActor
@Suite(.serialized) struct SettingsWindowTests {
    // 4 つのカテゴリをこの順に並べ、開くたびに「外観」を選ぶ。
    @Test func categoriesAreInOrderAndTheWindowOpensOnAppearance() {
        let harness = SettingsHarness()
        #expect(harness.window.categoryTitles == ["外観", "一般", "通知", "キーボード"])
        harness.window.present(makeKey: false)
        #expect(harness.window.selectedCategory == "外観")
        harness.window.tabs.selectedTabViewItemIndex = 2
        #expect(harness.window.selectedCategory == "通知")
        harness.window.present(makeKey: false)
        #expect(harness.window.selectedCategory == "外観")
        #expect(harness.window.window?.title == "設定")
    }

    // Scenario: Choose dark — すぐに `color_scheme: "dark"` を保存する（保存ボタンは無い）。
    @Test func choosingAThemeSavesItImmediately() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.appearancePane
        #expect(pane.radios[.system]?.state == .on)
        click(try #require(pane.radios[.dark]))
        #expect(await waitUntil { harness.api.patches == [ConfigPatch(colorScheme: .dark)] })
        #expect(harness.config.settings.display.colorScheme == .dark)
        #expect(pane.radios[.dark]?.state == .on)
        #expect(pane.radios[.system]?.state == .off)
    }

    // Scenario: Save failure — 前の値に戻し、エラーを出す。
    @Test func failedThemeSaveRevertsTheRadioAndShowsTheError() async throws {
        let harness = SettingsHarness()
        harness.api.failure = "保存に失敗しました"
        let pane = harness.window.appearancePane
        await pane.choose(.light)
        #expect(pane.radios[.system]?.state == .on)
        #expect(pane.radios[.light]?.state == .off)
        #expect(!pane.errorLabel.isHidden)
        #expect(pane.errorLabel.stringValue == "保存に失敗しました")
    }

    // MARK: - 一般

    // 確定の判定: 前後の空白を削り、空か変わっていなければ保存せずに戻す。
    @Test func shellCommitRules() {
        #expect(SettingsRules.shellCommit("  /bin/bash  ", persisted: "/bin/zsh") == .save("/bin/bash"))
        #expect(SettingsRules.shellCommit(" /bin/zsh ", persisted: "/bin/zsh") == .revert)
        #expect(SettingsRules.shellCommit("   ", persisted: "/bin/zsh") == .revert)
        #expect(SettingsRules.shellCommit("", persisted: "/bin/zsh") == .revert)
    }

    // shell field shows the current path, commits on blur and Enter, and skips unchanged values
    @Test func shellFieldCommitsTrimmedChangesAndSkipsUnchangedValues() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.generalPane
        #expect(pane.shellField.stringValue == "/bin/zsh")
        await pane.commitShell("  /bin/zsh ")
        await pane.commitShell("")
        #expect(harness.api.patches.isEmpty)
        #expect(pane.shellField.stringValue == "/bin/zsh")
        await pane.commitShell(" /bin/bash ")
        #expect(harness.api.patches == [ConfigPatch(shell: "/bin/bash")])
        #expect(pane.shellField.stringValue == "/bin/bash")
    }

    // Scenario: Invalid shell — デーモンが拒否したら、前のシェルに戻してエラーを出す。
    @Test func invalidShellRollsBackToTheLastPersistedValue() async throws {
        let harness = SettingsHarness()
        harness.api.reject = { $0.shell == "/no/such/shell" ? "shell: stat /no/such/shell: no such file or directory" : nil }
        let pane = harness.window.generalPane
        pane.shellField.stringValue = "/no/such/shell"
        await pane.commitShell(pane.shellField.stringValue)
        #expect(pane.shellField.stringValue == "/bin/zsh")
        #expect(harness.config.settings.general.shell == "/bin/zsh")
        #expect(pane.shellError.stringValue == "shell: stat /no/such/shell: no such file or directory")
        #expect(!pane.shellError.isHidden)
    }

    // agent session restore toggle reflects the stored value, persists immediately, and rolls back on failure
    @Test func restoreToggleReflectsPersistsAndRollsBack() async throws {
        let harness = SettingsHarness(ClientSettings(general: GeneralSettings(restoreEnabled: false)))
        let pane = harness.window.generalPane
        #expect(pane.restoreCheckbox.state == .off)
        await pane.setRestoreEnabled(true)
        #expect(harness.api.patches == [ConfigPatch(restore: .init(enabled: true))])
        #expect(pane.restoreCheckbox.state == .on)

        harness.api.failure = "保存に失敗しました"
        await pane.setRestoreEnabled(false)
        #expect(pane.restoreCheckbox.state == .on)
        #expect(pane.restoreError.stringValue == "保存に失敗しました")
    }

    // ブラウザ版で変えた設定は、読み直したら画面にも出る。
    @Test func reloadedValuesAreShown() async throws {
        let harness = SettingsHarness()
        harness.api.server.general.shell = "/bin/bash"
        harness.api.server.display.colorScheme = .light
        await harness.config.reload()
        #expect(harness.window.generalPane.shellField.stringValue == "/bin/bash")
        #expect(harness.window.appearancePane.radios[.light]?.state == .on)
    }
}

/// spec: settings-window「Notifications category」、notifications「User-initiated authorization」（tasks 4.3）。
///
/// webtabinal `web/tests/settings-modal.test.ts` のうち通知に関するケースを移したもの。
@MainActor
@Suite(.serialized) struct NotificationsPaneTests {
    private func settings(
        notification: NotificationSettings = NotificationSettings(commands: []),
        state: StateSettings = StateSettings()
    ) -> ClientSettings {
        ClientSettings(tabs: TabSettings(notification: notification), state: state)
    }

    // notification settings persist immediately and roll back with a visible error
    @Test func notificationSettingsPersistImmediatelyAndRollBackWithAVisibleError() async throws {
        let harness = SettingsHarness(settings())
        let pane = harness.window.notificationsPane
        #expect(pane.enabledCheckbox.state == .on)

        harness.api.holdPatches(true)
        click(pane.enabledCheckbox)
        #expect(await waitUntil { harness.api.patches == [ConfigPatch(notification: .init(enabled: false))] })
        // 保存中も、コントロールは新しい値を出す。保存中はこのカテゴリのコントロールを無効にする（保存中のロック）。
        #expect(pane.enabledCheckbox.state == .off)
        #expect(pane.isSaving)
        #expect(!pane.alwaysCheckbox.isEnabled)
        #expect(!pane.commandField.isEnabled)
        #expect(!pane.stateEnabledCheckbox.isEnabled)
        harness.api.holdPatches(false)
        #expect(await waitUntil { !pane.isSaving })
        #expect(pane.alwaysCheckbox.isEnabled)

        harness.api.reject = { $0.notification?.always == true ? "設定を保存できませんでした" : nil }
        await pane.save(ConfigPatch(notification: .init(always: true)))
        #expect(harness.api.patches.count == 2)
        // 失敗したら、最後に保存できた値に戻す。
        #expect(pane.enabledCheckbox.state == .off)
        #expect(pane.alwaysCheckbox.state == .off)
        #expect(pane.errorLabel.stringValue == "設定を保存できませんでした")
        #expect(!pane.errorLabel.isHidden)
    }

    // Scenario: Immediate save — 「通知を有効にする」を外すと、すぐに `notification.enabled: false` を送る。
    @Test func turningOffNotificationsSendsThePatchWithoutFurtherAction() async throws {
        let harness = SettingsHarness(settings())
        click(harness.window.notificationsPane.enabledCheckbox)
        #expect(await waitUntil { harness.config.committed.tabs.notification.enabled == false })
        #expect(harness.api.patches == [ConfigPatch(notification: .init(enabled: false))])
    }

    // notification permission is requested directly and refreshed on open and window focus
    @Test func permissionIsRequestedDirectlyAndRefreshedOnOpenAndFocus() async throws {
        let harness = SettingsHarness(settings())
        harness.notifier.permissionState = .default
        let pane = harness.window.notificationsPane

        harness.window.present(makeKey: false)
        #expect(await waitUntil { harness.notifier.queries == 1 })
        #expect(pane.permission == .default)
        #expect(!pane.permissionButton.isHidden)
        #expect(pane.permissionButton.title == "通知を許可")
        // 自動では許可を求めない。
        #expect(harness.notifier.requests == 0)

        await pane.requestPermission()
        #expect(harness.notifier.requests == 1)
        #expect(pane.permission == .granted)
        #expect(pane.permissionButton.isHidden)

        // アプリが前面に来たら読み直す（システム設定で拒否された）。
        harness.notifier.permissionState = .denied
        harness.window.refreshNotificationPermission()
        #expect(await waitUntil { pane.permission == .denied })
        #expect(pane.permissionButton.isHidden)
        #expect(pane.permissionGuidance.stringValue.contains("システム設定"))

        harness.notifier.permissionState = .unsupported
        harness.window.refreshNotificationPermission()
        #expect(await waitUntil { pane.permission == .unsupported })
        #expect(pane.permissionLabel.stringValue.contains("利用できません"))
        #expect(pane.permissionButton.isHidden)
        #expect(harness.notifier.requests == 1)
    }

    // agent state settings persist, disable dependents, and roll back invalid numbers
    @Test func agentStateSettingsPersistDisableDependentsAndRollBackInvalidNumbers() async throws {
        let harness = SettingsHarness(settings(notification: NotificationSettings(always: true, commands: [])))
        harness.api.reject = { patch in
            if let debounce = patch.state?.debounceMs, debounce < 20 { return "state.debounce_ms must be between 20 and 5000" }
            return nil
        }
        let pane = harness.window.notificationsPane
        #expect(pane.advancedBox.isHidden)
        pane.setAdvancedVisible(true)
        #expect(!pane.advancedBox.isHidden)

        click(pane.stateEnabledCheckbox)
        #expect(await waitUntil { harness.config.committed.state.enabled == false && !pane.isSaving })
        // Scenario: Detection off — 状態の通知の 2 項目と詳細設定を無効にする。
        #expect(!pane.notifyBlockedCheckbox.isEnabled)
        #expect(!pane.notifyIdleCheckbox.isEnabled)
        #expect(!pane.quiescenceField.isEnabled)
        #expect(pane.quiescenceField.stringValue == "1500")

        click(pane.stateEnabledCheckbox)
        #expect(await waitUntil { harness.config.committed.state.enabled && !pane.isSaving })
        #expect(pane.quiescenceField.isEnabled)
        await pane.commitAdvanced(pane.quiescenceField, "2000")
        #expect(pane.quiescenceField.stringValue == "2000")

        await pane.commitAdvanced(pane.debounceField, "1")
        #expect(pane.debounceField.stringValue == "120")
        #expect(pane.quiescenceField.stringValue == "2000")
        #expect(pane.errorLabel.stringValue == "state.debounce_ms must be between 20 and 5000")
        // 数値でないか変わっていなければ、保存せずに戻す。
        let count = harness.api.patches.count
        await pane.commitAdvanced(pane.bottomLinesField, "abc")
        await pane.commitAdvanced(pane.bottomLinesField, "15")
        #expect(harness.api.patches.count == count)
        #expect(pane.bottomLinesField.stringValue == "15")
        #expect(harness.config.settings.tabs.notification == NotificationSettings(always: true, commands: []))
    }

    @Test func numberParsingFollowsParseInt() {
        #expect(SettingsRules.parseInt("2000") == 2000)
        #expect(SettingsRules.parseInt("  12abc") == 12)
        #expect(SettingsRules.parseInt("-5") == -5)
        #expect(SettingsRules.parseInt("1.5") == 1)
        #expect(SettingsRules.parseInt("abc") == nil)
        #expect(SettingsRules.parseInt("") == nil)
        #expect(SettingsRules.numberCommit("120", persisted: 120) == nil)
        #expect(SettingsRules.numberCommit("200", persisted: 120) == 200)
    }

    @Test func manifestDirIsTrimmedAndSavedOnlyWhenChanged() async throws {
        let harness = SettingsHarness(settings())
        let pane = harness.window.notificationsPane
        await pane.commitAdvanced(pane.manifestDirField, "  ")
        #expect(harness.api.patches.isEmpty)
        await pane.commitAdvanced(pane.manifestDirField, " /tmp/manifests ")
        #expect(harness.api.patches == [ConfigPatch(state: .init(manifestDir: "/tmp/manifests"))])
        #expect(pane.manifestDirField.stringValue == "/tmp/manifests")
    }

    // screen-derived prompt return toggle is off by default, persists, and follows detection
    @Test func promptReturnToggleIsOffByDefaultPersistsAndFollowsDetection() async throws {
        let harness = SettingsHarness(settings())
        let pane = harness.window.notificationsPane
        #expect(pane.notifyIdleCheckbox.state == .off)
        click(pane.notifyIdleCheckbox)
        #expect(await waitUntil { harness.config.committed.state.notifyOnIdle && !pane.isSaving })
        #expect(harness.api.patches == [ConfigPatch(state: .init(notifyOnIdle: true))])

        await pane.save(ConfigPatch(state: .init(enabled: false)))
        #expect(!pane.notifyIdleCheckbox.isEnabled)
        await pane.save(ConfigPatch(state: .init(enabled: true)))
        #expect(pane.notifyIdleCheckbox.isEnabled)

        harness.api.failure = "保存に失敗しました"
        click(pane.notifyIdleCheckbox)
        #expect(await waitUntil { pane.errorLabel.stringValue == "保存に失敗しました" && !pane.isSaving })
        #expect(pane.notifyIdleCheckbox.state == .on)
    }

    // notification command whitelist can be listed, added and removed
    @Test func commandWhitelistCanBeListedAddedAndRemoved() async throws {
        let harness = SettingsHarness(settings(notification: NotificationSettings(always: true, commands: ["claude", "codex"])))
        let pane = harness.window.notificationsPane
        #expect(pane.listedCommands == ["claude", "codex"])

        pane.commandField.stringValue = "  make  "
        await pane.addCommand(pane.commandField.stringValue)
        #expect(harness.api.patches == [ConfigPatch(notification: .init(commands: ["claude", "codex", "make"]))])
        #expect(pane.listedCommands == ["claude", "codex", "make"])
        #expect(pane.commandField.stringValue == "")

        await pane.addCommand("   ")
        await pane.addCommand("claude")
        // Scenario: Add command — 大文字小文字だけが違う重複も保存しない。
        await pane.addCommand(" Codex ")
        #expect(harness.api.patches.count == 1)
        #expect(SettingsRules.addingCommand("Claude", to: ["claude"]) == nil)

        await pane.removeCommand("codex")
        #expect(harness.api.patches.last == ConfigPatch(notification: .init(commands: ["claude", "make"])))
        #expect(pane.listedCommands == ["claude", "make"])
    }

    // 空の一覧は「すべてのセッションが通知します」と説明する。
    @Test func emptyCommandListIsDescribed() throws {
        let harness = SettingsHarness(settings(notification: NotificationSettings(commands: [])))
        let pane = harness.window.notificationsPane
        let label = try #require(pane.commandList.subviews.first as? NSTextField)
        #expect(label.stringValue == "すべてのセッションが通知します")
    }

    // a failed command patch is reported and rolled back
    @Test func aFailedCommandPatchIsReportedAndRolledBack() async throws {
        let harness = SettingsHarness(settings(notification: NotificationSettings(always: true, commands: ["claude"])))
        harness.api.failure = "設定を保存できませんでした"
        let pane = harness.window.notificationsPane
        await pane.addCommand("make")
        #expect(pane.listedCommands == ["claude"])
        #expect(pane.errorLabel.stringValue == "設定を保存できませんでした")
    }
}

/// spec: settings-window「Keyboard category」（tasks 4.4）。
@MainActor
@Suite(.serialized) struct KeyboardPaneTests {
    private func stroke(_ characters: String, keyCode: UInt16, modifiers: KeyInput.Modifiers = []) -> KeyStroke {
        KeyStroke(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: characters, modifiers: modifiers)
    }

    // KeyRecorder: Escape で取り消す、修飾キーだけは無視する、次のキーを表記にして渡す。
    @Test func recorderCancelsOnEscapeIgnoresModifiersAndRecordsTheNextKey() {
        let recorder = KeyRecorder()
        var recorded: [String] = []
        var cancelled = 0
        recorder.onRecord = { recorded.append($0) }
        recorder.onCancel = { cancelled += 1 }

        #expect(!recorder.handle(stroke("k", keyCode: 0x28)))
        recorder.start(monitorEvents: false)
        #expect(recorder.handle(stroke("", keyCode: 0x3B, modifiers: .control)))
        #expect(recorder.isRecording)
        #expect(recorder.handle(stroke("\u{1b}", keyCode: 0x35)))
        #expect(cancelled == 1)
        #expect(!recorder.isRecording)

        recorder.start(monitorEvents: false)
        #expect(recorder.handle(stroke("k", keyCode: 0x28, modifiers: .control)))
        #expect(recorded == ["ctrl+k"])
        #expect(!recorder.isRecording)
    }

    // Scenario: Record prefix — `key_bindings.prefix: "ctrl+k"` を保存し、すぐにコードで使える。
    @Test func recordedPrefixIsSavedAndUsedImmediately() async throws {
        let shell = try ShellHarness(settings: TabSettings(keyBindings: KeyBindings(enabled: true)))
        let window = SettingsWindowController(
            config: shell.config, editor: shell.shell.editor, notifications: shell.notifier, theme: .dark
        )
        let pane = window.keyboardPane
        pane.loadViewIfNeeded()
        pane.monitorKeyEvents = false
        #expect(pane.buttonTitle(.prefix) == "Ctrl+J")

        pane.startRecording(.prefix)
        #expect(pane.buttonTitle(.prefix) == "キーを入力…")
        pane.recorder.handle(stroke("k", keyCode: 0x28, modifiers: .control))
        #expect(await waitUntil { shell.config.committed.tabs.keyBindings.prefix == "ctrl+k" })
        #expect(shell.configAPI.patches.last?.keyBindings?.prefix == "ctrl+k")
        #expect(pane.buttonTitle(.prefix) == "Ctrl+K")
        #expect(shell.shell.chord.bindings.prefix == "ctrl+k")
    }

    // Scenario: Reserved — Command-N は予約済みとして拒否し、前のプレフィックスのまま。
    @Test func reservedBindingIsRejectedAndThePreviousPrefixRemains() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.keyboardPane
        pane.startRecording(.prefix)
        pane.recorder.handle(stroke("n", keyCode: 0x2D, modifiers: .command))
        #expect(await waitUntil { !pane.bindingsError.isHidden })
        #expect(pane.bindingsError.stringValue == "既存のショートカット（Cmd+1〜9 / Cmd+N / Cmd+C / Cmd+V）と衝突しています")
        #expect(pane.buttonTitle(.prefix) == "Ctrl+J")
        #expect(harness.api.patches.isEmpty)

        // 次のタブとサイドバー開閉に同じキーは使えない。
        pane.startRecording(.nextTab)
        pane.recorder.handle(stroke("j", keyCode: 0x26))
        #expect(await waitUntil { pane.bindingsError.stringValue == "移動キーとサイドバー開閉キーに同じキーは使えません" })
        #expect(pane.buttonTitle(.nextTab) == "N")
    }

    // Escape で記録を取り消すと、ボタンは元の表記に戻り、何も保存しない。
    @Test func escapeCancelsRecording() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.keyboardPane
        pane.startRecording(.prevTab)
        pane.recorder.handle(stroke("\u{1b}", keyCode: 0x35))
        #expect(pane.buttonTitle(.prevTab) == "P")
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.api.patches.isEmpty)
    }

    // キー割り当てをリセット: 既定に戻し、有効かどうかはそのまま。
    @Test func resetRestoresTheDefaultsAndKeepsEnabled() async throws {
        let harness = SettingsHarness(ClientSettings(tabs: TabSettings(keyBindings: KeyBindings(enabled: true, prefix: "ctrl+k", nextTab: "l"))))
        let pane = harness.window.keyboardPane
        click(pane.resetButton)
        #expect(await waitUntil { harness.config.committed.tabs.keyBindings == KeyBindings(enabled: true) })
        #expect(harness.api.patches == [ConfigPatch(keyBindings: KeyBindings(enabled: true))])
        #expect(SettingsRules.resetBindings(keepingEnabledFrom: KeyBindings(enabled: false, prefix: "alt+x")) == KeyBindings())
    }

    @Test func enablingShortcutsSavesTheWholeObject() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.keyboardPane
        #expect(pane.shortcutsCheckbox.state == .off)
        click(pane.shortcutsCheckbox)
        #expect(await waitUntil { harness.config.committed.tabs.keyBindings.enabled })
        #expect(harness.api.patches == [ConfigPatch(keyBindings: KeyBindings(enabled: true))])
    }

    // Shift+Enter newline toggle persists immediately and rolls back with a visible error
    @Test func shiftEnterTogglePersistsAndRollsBack() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.keyboardPane
        #expect(pane.shiftEnterCheckbox.state == .on)
        await pane.setShiftEnterNewline(false)
        #expect(harness.api.patches == [ConfigPatch(shiftEnterNewline: false)])
        #expect(pane.shiftEnterCheckbox.state == .off)

        harness.api.failure = "保存に失敗しました"
        await pane.setShiftEnterNewline(true)
        #expect(pane.shiftEnterCheckbox.state == .off)
        #expect(pane.shiftEnterError.stringValue == "保存に失敗しました")
    }
}

/// レビューで見つかった不具合（tasks 6.2）。
@MainActor
@Suite(.serialized) struct SettingsReviewFixTests {
    // 編集中に読み直しで値が変わっても、何も入力せずに確定したら、古い値で上書きしない（新しい値を出す）。
    @Test func unchangedShellFieldDoesNotOverwriteAValueChangedElsewhere() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.generalPane
        pane.isEditing = { $0 === pane.shellField }
        harness.api.server.general.shell = "/bin/bash"
        await harness.config.reload()
        #expect(pane.shellField.stringValue == "/bin/zsh")

        pane.isEditing = { _ in false }
        await pane.commitShell(pane.shellField.stringValue)
        #expect(harness.api.patches.isEmpty)
        #expect(pane.shellField.stringValue == "/bin/bash")
        #expect(harness.config.settings.general.shell == "/bin/bash")
    }

    @Test func unchangedAdvancedFieldDoesNotOverwriteAValueChangedElsewhere() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.notificationsPane
        pane.isEditing = { $0 === pane.quiescenceField }
        harness.api.server.state.quiescenceMs = 3000
        await harness.config.reload()
        #expect(pane.quiescenceField.stringValue == "1500")

        pane.isEditing = { _ in false }
        await pane.commitAdvanced(pane.quiescenceField, pane.quiescenceField.stringValue)
        #expect(harness.api.patches.isEmpty)
        #expect(pane.quiescenceField.stringValue == "3000")
    }

    // 保存中に次のシェルを確定したら、保存が終わってから保存する（黙って捨てない）。
    @Test func shellCommittedWhileSavingIsSavedAfterwards() async throws {
        let harness = SettingsHarness()
        let pane = harness.window.generalPane
        harness.api.holdPatches(true)
        let first = Task { await pane.commitShell("/bin/bash") }
        #expect(await waitUntil { harness.api.patches.count == 1 })
        await pane.commitShell("/bin/sh")
        harness.api.holdPatches(false)
        await first.value
        #expect(harness.api.patches == [ConfigPatch(shell: "/bin/bash"), ConfigPatch(shell: "/bin/sh")])
        #expect(harness.config.committed.general.shell == "/bin/sh")
        #expect(pane.shellField.stringValue == "/bin/sh")
    }

    // 追加に失敗したら、入力したコマンドを欄に残す（成功したら空にする）。
    @Test func failedCommandAddKeepsTheDraft() async throws {
        let harness = SettingsHarness(ClientSettings(tabs: TabSettings(notification: NotificationSettings(commands: ["claude"]))))
        let pane = harness.window.notificationsPane
        harness.api.failure = "設定を保存できませんでした"
        pane.commandField.stringValue = "make"
        await pane.addCommand(pane.commandField.stringValue)
        #expect(pane.commandField.stringValue == "make")
        #expect(pane.listedCommands == ["claude"])
        harness.api.failure = nil
        await pane.addCommand(pane.commandField.stringValue)
        #expect(pane.commandField.stringValue == "")
        #expect(pane.listedCommands == ["claude", "make"])
    }
}

/// `sidebar_width` が、折りたたんでいる間・最初のレイアウトの前に変わったとき（tasks 6.2）。
@MainActor
@Suite(.serialized) struct SidebarWidthReviewFixTests {
    @Test func widthChangedWhileCollapsedIsAppliedOnExpand() async throws {
        let harness = try ShellHarness(settings: TabSettings(sidebarWidth: 240))
        let split = harness.shell.splitViewController
        split.setSidebarCollapsed(true, animated: false)
        harness.configAPI.server.tabs.sidebarWidth = 320
        await harness.config.reload()
        split.setSidebarCollapsed(false, animated: false)
        split.view.layoutSubtreeIfNeeded()
        #expect(abs(split.sidebarWidth - 320) < 1)
    }

    @Test func widthChangedBeforeTheFirstLayoutIsUsed() {
        let palette = ChromePalette.dark
        let split = ShellSplitViewController(
            sidebar: SidebarViewController(palette: palette),
            terminalArea: TerminalAreaViewController(terminalView: TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark), palette: palette),
            sidebarWidth: 240
        )
        split.applyConfiguredWidth(360)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1000, height: 600))
        split.view.layoutSubtreeIfNeeded()
        #expect(abs(split.sidebarWidth - 360) < 1)
    }
}
