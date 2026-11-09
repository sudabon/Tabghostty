import Foundation
import Testing
@testable import DaemonClient

/// phase3: `GET /api/config` から読む、タブとサイドバーの設定（sidebar_width、confirm_close_running、
/// quit_when_no_tabs、notification、key_bindings）。
@Suite struct TabSettingsTests {
    private func settings(_ json: String) throws -> TabSettings {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return ClientSettings(json: object).tabs
    }

    @Test func missingKeysUseTheDaemonDefaults() throws {
        let tabs = try settings("{}")
        #expect(tabs == TabSettings())
        #expect(tabs.sidebarWidth == 240)
        #expect(tabs.confirmCloseRunning)
        #expect(tabs.quitWhenNoTabs)
        #expect(tabs.notification == NotificationSettings(enabled: true, always: false, minDurationMs: 0, commands: ["claude", "codex", "cursor-agent", "agent"]))
        #expect(tabs.keyBindings == KeyBindings(enabled: false, prefix: "ctrl+j", nextTab: "n", prevTab: "p", toggleSidebar: "j"))
    }

    @Test func valuesAreRead() throws {
        let tabs = try settings("""
        {
          "sidebar_width": 300,
          "confirm_close_running": false,
          "quit_when_no_tabs": false,
          "notification": {"enabled": false, "always": true, "min_duration_ms": 5000, "commands": ["claude"]},
          "key_bindings": {"enabled": true, "prefix": "ctrl+k", "next_tab": "l", "prev_tab": "h", "toggle_sidebar": "b"},
          "future": 1
        }
        """)
        #expect(tabs.sidebarWidth == 300)
        #expect(tabs.confirmCloseRunning == false)
        #expect(tabs.quitWhenNoTabs == false)
        #expect(tabs.notification == NotificationSettings(enabled: false, always: true, minDurationMs: 5000, commands: ["claude"]))
        #expect(tabs.keyBindings == KeyBindings(enabled: true, prefix: "ctrl+k", nextTab: "l", prevTab: "h", toggleSidebar: "b"))
    }

    @Test func invalidValuesFallBackToDefaults() throws {
        let tabs = try settings("""
        {
          "sidebar_width": -5,
          "confirm_close_running": 0,
          "quit_when_no_tabs": "no",
          "notification": {"enabled": 1, "min_duration_ms": -1},
          "key_bindings": {"enabled": "true", "prefix": "", "next_tab": 3}
        }
        """)
        #expect(tabs == TabSettings())
    }

    // phase4: 設定画面で編集する項目（shell、restore.enabled、state.*）と、notification.commands の扱い。
    @Test func settingsWindowValuesAreRead() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data("""
        {
          "shell": "/bin/bash",
          "restore": {"enabled": false, "commands": {"claude": "claude --continue"}},
          "state": {"enabled": false, "debounce_ms": 200, "quiescence_ms": 0, "bottom_lines": 30,
                    "notify_on_blocked": false, "notify_on_idle": true, "manifest_dir": "/tmp/m"},
          "notification": {"commands": []}
        }
        """.utf8)) as? [String: Any])
        let settings = ClientSettings(json: object)
        #expect(settings.general == GeneralSettings(shell: "/bin/bash", restoreEnabled: false))
        #expect(settings.state == StateSettings(
            enabled: false, debounceMs: 200, quiescenceMs: 0, bottomLines: 30,
            notifyOnBlocked: false, notifyOnIdle: true, manifestDir: "/tmp/m"
        ))
        // 空の一覧は「すべてのセッションが通知する」のまま（既定の一覧にしない）。
        #expect(settings.tabs.notification.commands.isEmpty)
    }

    @Test func missingSettingsWindowValuesUseTheDaemonDefaults() throws {
        let settings = ClientSettings(json: ["notification": ["commands": NSNull()]])
        #expect(settings.general == GeneralSettings(shell: "/bin/zsh", restoreEnabled: true))
        #expect(settings.state == StateSettings(
            enabled: true, debounceMs: 120, quiescenceMs: 1500, bottomLines: 15,
            notifyOnBlocked: true, notifyOnIdle: false, manifestDir: ""
        ))
        #expect(settings.tabs.notification.commands == NotificationSettings.defaultCommands)
    }

    @Test func configPatchEncodesOnlyTheGivenKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(ConfigPatch(sidebarWidth: 300)), as: UTF8.self) == #"{"sidebar_width":300}"#)
        #expect(String(decoding: try encoder.encode(ConfigPatch()), as: UTF8.self) == "{}")
        #expect(ConfigPatch().keys.isEmpty)
    }

    // 入れ子のオブジェクトには、変更したキーだけを入れる。commands と key_bindings は全体を送る（phase4 design D3）。
    @Test func configPatchNestsOnlyTheChangedKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func json(_ patch: ConfigPatch) throws -> String {
            String(decoding: try encoder.encode(patch), as: UTF8.self)
        }
        #expect(try json(ConfigPatch(colorScheme: .dark)) == #"{"color_scheme":"dark"}"#)
        #expect(try json(ConfigPatch(notification: .init(enabled: false))) == #"{"notification":{"enabled":false}}"#)
        #expect(try json(ConfigPatch(notification: .init(commands: ["claude", "make"]))) == #"{"notification":{"commands":["claude","make"]}}"#)
        #expect(try json(ConfigPatch(notification: .init(commands: []))) == #"{"notification":{"commands":[]}}"#)
        #expect(try json(ConfigPatch(state: .init(notifyOnIdle: true, debounceMs: 200))) == #"{"state":{"debounce_ms":200,"notify_on_idle":true}}"#)
        #expect(try json(ConfigPatch(restore: .init(enabled: false))) == #"{"restore":{"enabled":false}}"#)
        #expect(try json(ConfigPatch(shell: "/bin/bash", shiftEnterNewline: false)) == #"{"shell":"\/bin\/bash","shift_enter_newline":false}"#)
        #expect(try json(ConfigPatch(keyBindings: KeyBindings(enabled: true, prefix: "ctrl+k"))) ==
            #"{"key_bindings":{"enabled":true,"next_tab":"n","prefix":"ctrl+k","prev_tab":"p","toggle_sidebar":"j"}}"#)
    }

    @Test func configPatchKeysAndOptimisticApply() {
        let patch = ConfigPatch(
            colorScheme: .light,
            keyBindings: KeyBindings(enabled: true),
            notification: .init(always: true, commands: ["make"]),
            state: .init(enabled: false, manifestDir: "/tmp"),
            restore: .init(enabled: false)
        )
        #expect(patch.keys == [.colorScheme, .keyBindings, .notificationAlways, .notificationCommands, .stateEnabled, .stateManifestDir, .restoreEnabled])
        var settings = ClientSettings()
        patch.apply(to: &settings)
        #expect(settings.display.colorScheme == .light)
        #expect(settings.tabs.keyBindings.enabled)
        #expect(settings.tabs.notification.always)
        #expect(settings.tabs.notification.enabled)
        #expect(settings.tabs.notification.commands == ["make"])
        #expect(!settings.state.enabled)
        #expect(settings.state.manifestDir == "/tmp")
        #expect(!settings.general.restoreEnabled)
        #expect(ConfigKey.changes(from: ClientSettings(), to: settings) == patch.keys)
    }
}
