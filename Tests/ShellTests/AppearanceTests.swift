import AppKit
import DaemonClient
import Testing
import TerminalCore
import TerminalUI
@testable import Shell

/// spec: color-scheme（tasks 2.1）。webtabinal `web/tests/theme.test.ts`（3 件）を移したもの。
@MainActor
@Suite(.serialized) struct ThemeTests {
    // xterm boosts cell contrast to WCAG AA so dark-on-black TUI text stays readable
    @Test func terminalBoostsCellContrastToWCAGAA() {
        #expect(ContrastAdjuster.minimumRatio == 4.5)
        let light = ResolvedTheme.light.palette
        #expect(light.background == ColorRGB(hex: 0xffffff))
        #expect(light.foreground == ColorRGB(hex: 0x333333))
        #expect(ResolvedTheme.dark.palette.background == ColorRGB(hex: 0x1e1e1e))
    }

    // xterm palette hex stays in sync with daemon OSC palette（webtabinal `internal/osc/color.go` の LightPalette / DarkPalette）
    @Test func paletteStaysInSyncWithTheDaemonOSCPalette() {
        let dark = ResolvedTheme.dark.palette
        let light = ResolvedTheme.light.palette
        #expect((dark.foreground, dark.background, dark.cursor) == (ColorRGB(hex: 0xcccccc), ColorRGB(hex: 0x1e1e1e), ColorRGB(hex: 0xffffff)))
        #expect((light.foreground, light.background, light.cursor) == (ColorRGB(hex: 0x333333), ColorRGB(hex: 0xffffff), ColorRGB(hex: 0x000000)))
        // chrome の背景は端末の背景と同じ（Web 版の `--bg`）。
        #expect(ResolvedTheme.dark.chrome.background.rgb == dark.background)
        #expect(ResolvedTheme.light.chrome.background.rgb == light.background)
    }

    // TerminalView applies xtermViewOptions on create and theme change
    @Test func terminalAppliesThePaletteOnCreateAndThemeChange() async throws {
        let harness = try ShellHarness(client: client(.dark))
        await harness.liveSessions([session("a"), session("b")])
        #expect(harness.terminalView.palette == .dark)
        for controller in harness.coordinator.allControllers {
            #expect(try await snapshotColors(controller).background == Palette.dark.background)
        }

        harness.configAPI.server.display.colorScheme = .light
        await harness.config.reload()
        #expect(harness.terminalView.palette == .light)
        #expect(await waitUntil {
            for controller in harness.coordinator.allControllers {
                guard (try? await snapshotColors(controller).background) == Palette.light.background else { return false }
            }
            return true
        })
        // 切り替えた後に作る端末も、新しい配色で作る。
        await harness.deliver(.sessions([session("a"), session("b"), session("c")]))
        let created = try #require(harness.coordinator.controller(for: "c"))
        #expect(try await snapshotColors(created).foreground == Palette.light.foreground)
    }

    private func snapshotColors(_ controller: TerminalController) async throws -> FrameColors {
        let snapshot = try #require(await controller.makeSnapshot(forceFull: true))
        return snapshot.colors
    }
}

private func client(_ scheme: ColorSchemeSetting) -> ClientSettings {
    var settings = ClientSettings()
    settings.display.colorScheme = scheme
    return settings
}

/// spec: color-scheme「Scheme resolution」「Scheme applies everywhere」（tasks 2.1 / 2.2）。
@MainActor
@Suite(.serialized) struct AppearanceControllerTests {
    @Test func resolution() {
        #expect(ResolvedTheme.resolve(.light, systemIsDark: true) == .light)
        #expect(ResolvedTheme.resolve(.dark, systemIsDark: false) == .dark)
        #expect(ResolvedTheme.resolve(.system, systemIsDark: true) == .dark)
        #expect(ResolvedTheme.resolve(.system, systemIsDark: false) == .light)
    }

    // Scenario: Follow system — system のときは、macOS の外観の切り替えに再起動せずに追従する。
    @Test func systemSchemeFollowsTheSystemAppearance() {
        let controller = AppearanceController(scheme: .system, application: nil)
        var changes: [ResolvedTheme] = []
        controller.onChange = { changes.append($0) }
        #expect(controller.theme == .light)
        controller.systemAppearanceDidChange(isDark: true)
        #expect(controller.theme == .dark)
        controller.systemAppearanceDidChange(isDark: true)
        controller.systemAppearanceDidChange(isDark: false)
        #expect(changes == [.dark, .light])
    }

    // Scenario: Fixed scheme — light なら macOS がダークでもライト。
    @Test func fixedSchemeIgnoresTheSystemAppearance() {
        let controller = AppearanceController(scheme: .light, application: nil)
        var changes: [ResolvedTheme] = []
        controller.onChange = { changes.append($0) }
        controller.systemAppearanceDidChange(isDark: true)
        #expect(controller.theme == .light)
        #expect(changes.isEmpty)
        controller.scheme = .system
        #expect(controller.theme == .dark)
        #expect(changes == [.dark])
    }

    // 実際の NSApplication の外観を KVO で監視する（初期値はシステムの外観）。
    @Test func observesTheApplicationAppearance() {
        let app = NSApplication.shared
        let controller = AppearanceController(scheme: .system, application: app)
        #expect(controller.systemIsDark == AppearanceController.isDark(app.effectiveAppearance))
    }

    // Scenario: Switch from settings — 端末・サイドバー・ウィンドウがすぐに切り替わる（保存を待たない）。
    @Test func switchingSchemeRepaintsTerminalSidebarAndWindowImmediately() async throws {
        let harness = try ShellHarness(client: client(.dark))
        harness.configAPI.holdPatches(true)
        var themes: [ResolvedTheme] = []
        harness.shell.onThemeChange = { themes.append($0) }

        let save = Task { try await harness.shell.editor.apply(ConfigPatch(colorScheme: .light)) }
        #expect(await waitUntil { harness.terminalView.palette == .light })
        #expect(harness.shell.sidebar.palette == .light)
        #expect(harness.shell.terminalArea.palette == .light)
        #expect(harness.window.backgroundColor == ChromePalette.light.background.nsColor)
        #expect(themes == [.light])
        harness.configAPI.holdPatches(false)
        try await save.value
        #expect(harness.config.committed.display.colorScheme == .light)
    }

    // Scenario: Save fails — 前の配色に戻り、エラーが出る。
    @Test func failedSaveRestoresThePreviousScheme() async throws {
        let harness = try ShellHarness(client: client(.dark))
        harness.configAPI.failure = "color_scheme must be one of"
        var themes: [ResolvedTheme] = []
        harness.shell.onThemeChange = { themes.append($0) }
        await #expect(throws: FakeConfigAPI.Failure.self) {
            try await harness.shell.editor.apply(ConfigPatch(colorScheme: .light))
        }
        #expect(harness.terminalView.palette == .dark)
        #expect(harness.shell.sidebar.palette == .dark)
        #expect(themes == [.light, .dark])
    }
}

/// spec: settings-window「Configuration changes take effect without restart」（tasks 1.3）。
@MainActor
@Suite(.serialized) struct ConfigApplyTests {
    // Scenario: Font change — 全端末が 16pt で描き直し、新しいグリッドで resize を送る。
    @Test func fontSizeChangeRedrawsAndResizesEveryTerminal() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b")])
        #expect(await waitUntil { harness.terminalView.appliedGrid != nil })
        let before = try #require(harness.terminalView.appliedGrid)
        harness.sink.removeAll()

        harness.configAPI.server.display.fontSize = 16
        await harness.config.reload()
        #expect(harness.terminalView.fonts.size == 16)
        #expect(await waitUntil { harness.terminalView.appliedGrid != before })
        // 両方のセッションに、新しいグリッド（最後に知らせたもの）で resize を送る。
        #expect(await waitUntil {
            guard let after = harness.terminalView.appliedGrid else { return false }
            let resizes = harness.sink.resizes
            return resizes.contains("a:\(after.cols)x\(after.rows)") && resizes.contains("b:\(after.cols)x\(after.rows)")
        })
        let after = try #require(harness.terminalView.appliedGrid)
        #expect(after.cols < before.cols)
        #expect(after.cellWidthPx > before.cellWidthPx)
    }

    @Test func fontFamilyChangeIsApplied() async throws {
        let harness = try ShellHarness()
        harness.configAPI.server.display.fontFamily = "Courier New, monospace"
        await harness.config.reload()
        #expect(harness.terminalView.fontFamily == "Courier New, monospace")
    }

    @Test func sidebarWidthChangeMovesTheDivider() async throws {
        let harness = try ShellHarness(settings: TabSettings(sidebarWidth: 240))
        harness.configAPI.server.tabs.sidebarWidth = 320
        await harness.config.reload()
        harness.shell.splitViewController.view.layoutSubtreeIfNeeded()
        #expect(abs(harness.shell.splitViewController.sidebarWidth - 320) < 1)
    }

    // ドラッグで変えた幅は `ConfigEditor` で保存する。
    @Test func draggedSidebarWidthIsSaved() async throws {
        let harness = try ShellHarness(settings: TabSettings(sidebarWidth: 240))
        harness.shell.splitViewController.simulateDividerDrag(to: 300)
        #expect(await waitUntil { harness.configAPI.patches == [ConfigPatch(sidebarWidth: 300)] })
        #expect(await waitUntil { harness.config.committed.tabs.sidebarWidth == 300 })
    }

    // scrollback_lines は、作成済みの端末にも反映する（libghostty は上限をいつでも変えられる）。
    @Test func scrollbackChangeReachesExistingTerminals() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a")])
        harness.configAPI.server.display.scrollbackLines = 500
        await harness.config.reload()
        let controller = try #require(harness.coordinator.controller(for: "a"))
        #expect(await waitUntil { await controller.maxScrollback == 500 })
    }

    @Test func inputSettingsAndKeyBindingsAreAppliedImmediately() async throws {
        let harness = try ShellHarness()
        #expect(harness.terminalView.inputSettings.shiftEnterNewline)
        #expect(!harness.shell.chord.isEnabled)
        harness.configAPI.server.display.shiftEnterNewline = false
        harness.configAPI.server.display.copyOnSelect = true
        harness.configAPI.server.tabs.keyBindings = KeyBindings(enabled: true, prefix: "ctrl+k")
        await harness.config.reload()
        #expect(!harness.terminalView.inputSettings.shiftEnterNewline)
        #expect(harness.terminalView.inputSettings.copyOnSelect)
        #expect(harness.shell.chord.isEnabled)
        #expect(harness.shell.chord.bindings.prefix == "ctrl+k")
    }

    // confirm_close_running と quit_when_no_tabs は、参照のたびに `ConfigStore` から読む。
    @Test func tabPoliciesReadTheCurrentSettings() async throws {
        let harness = try ShellHarness()
        #expect(harness.shell.settings.confirmCloseRunning)
        harness.configAPI.server.tabs.confirmCloseRunning = false
        harness.configAPI.server.tabs.quitWhenNoTabs = false
        await harness.config.reload()
        #expect(!harness.shell.settings.confirmCloseRunning)
        #expect(!harness.shell.settings.quitWhenNoTabs)
    }
}
