import AppKit
import Testing
@testable import TabghosttyApp

/// spec: terminal-clipboard「Edit menu」。
@MainActor
@Suite struct AppMenuTests {
    // Copy / Paste は target を持たず、first responder（端末、またはテキストフィールド）に送る。
    @Test func editMenuHasCopyAndPaste() throws {
        let menu = AppMenu.make()
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let copy = try #require(edit.items.first { $0.title == "Copy" })
        #expect(copy.action == #selector(NSText.copy(_:)))
        #expect(copy.keyEquivalent == "c")
        #expect(copy.keyEquivalentModifierMask == .command)
        #expect(copy.target == nil)

        let paste = try #require(edit.items.first { $0.title == "Paste" })
        #expect(paste.action == #selector(NSText.paste(_:)))
        #expect(paste.keyEquivalent == "v")
        #expect(paste.keyEquivalentModifierMask == .command)
        #expect(paste.target == nil)
    }
    // spec: keyboard-shortcuts「Command shortcuts」— Command-N と Command-1〜9 はメニューのキー等価物。
    @Test func fileAndWindowMenusHaveTheTabShortcuts() throws {
        let menu = AppMenu.make()
        let file = try #require(menu.items.compactMap(\.submenu).first { $0.title == "File" })
        let newTab = try #require(file.items.first { $0.title == "新規タブ" })
        #expect(newTab.keyEquivalent == "n")
        #expect(newTab.keyEquivalentModifierMask == .command)
        #expect(newTab.action == #selector(TabMenuActions.newTab(_:)))
        #expect(newTab.target == nil)

        let window = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Window" })
        let tabs = window.items.filter { $0.action == #selector(TabMenuActions.selectTabFromMenu(_:)) }
        #expect(tabs.map(\.title) == (1...9).map { "タブ \($0)" })
        #expect(tabs.map(\.keyEquivalent) == (1...9).map(String.init))
        #expect(tabs.map(\.tag) == Array(1...9))
        #expect(tabs.allSatisfy { $0.keyEquivalentModifierMask == .command && $0.target == nil })
    }

    // spec: tab-sidebar「Sidebar collapse」— View メニューの「サイドバーを表示/隠す」（キー等価物なし）。
    @Test func viewMenuTogglesTheSidebarWithoutAKeyEquivalent() throws {
        let menu = AppMenu.make()
        let view = try #require(menu.items.compactMap(\.submenu).first { $0.title == "View" })
        let toggle = try #require(view.items.first { $0.title == "サイドバーを表示/隠す" })
        #expect(toggle.keyEquivalent == "")
        #expect(toggle.action == #selector(TabMenuActions.toggleTabSidebar(_:)))
    }

    // spec: settings-window「Settings window layout」— Command-, で設定画面を開く。接続する前は押せない。
    @Test func appMenuOpensSettingsWithCommandComma() throws {
        let menu = AppMenu.make()
        let app = try #require(menu.items.first?.submenu)
        let settings = try #require(app.items.first { $0.title == "設定…" })
        #expect(settings.keyEquivalent == ",")
        #expect(settings.keyEquivalentModifierMask == .command)
        #expect(settings.action == #selector(TabMenuActions.openSettings(_:)))
        #expect(settings.target == nil)
        #expect(!AppDelegate().validateMenuItem(settings))
    }

    // 接続する前（タブが無い）は、タブの操作を押せない。
    @Test func tabMenuItemsAreDisabledBeforeConnecting() throws {
        let delegate = AppDelegate()
        let menu = AppMenu.make()
        let items = menu.items.compactMap(\.submenu).flatMap(\.items).filter {
            [#selector(TabMenuActions.newTab(_:)), #selector(TabMenuActions.selectTabFromMenu(_:)), #selector(TabMenuActions.toggleTabSidebar(_:))]
                .contains($0.action)
        }
        #expect(items.count == 11)
        #expect(items.allSatisfy { !delegate.validateMenuItem($0) })
    }
}
