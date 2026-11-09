import AppKit
import Testing
@testable import TabghosttyApp
import TerminalUI

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
    // テキストフィールド（メモ・設定）で、取り消し・やり直し・カット・すべて選択が使える。
    @Test func editMenuHasTheStandardTextEditingItems() throws {
        let menu = AppMenu.make()
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let expected: [(title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ]
        for item in expected {
            let found = try #require(edit.items.first { $0.title == item.title })
            #expect(found.action == item.action)
            #expect(found.keyEquivalent == item.key)
            #expect(found.keyEquivalentModifierMask == item.modifiers)
            #expect(found.target == nil)
        }
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

/// spec: app-shell「Version information in About」— About パネルにバージョンと同梱のデーモンを出す。
@MainActor
@Suite struct AboutPanelTests {
    // About は AppDelegate に送り、接続する前でも押せる。
    @Test func appMenuShowsTheAboutPanelThroughTheDelegate() throws {
        let menu = AppMenu.make()
        let app = try #require(menu.items.first?.submenu)
        let about = try #require(app.items.first)
        #expect(about.title == "About \(WindowTitle.appName)")
        #expect(about.action == #selector(AppMenuActions.showAboutPanel(_:)))
        #expect(about.target == nil)
        #expect(AppDelegate().validateMenuItem(about))
    }

    @Test func optionsCarryTheVersionAndTheBundledDaemonRevision() throws {
        let options = AboutPanel.options(info: [
            "CFBundleShortVersionString": "0.7.0",
            "CFBundleVersion": "42",
            "TabghosttyDaemonRevision": "tabghostty-477813d-dirty",
        ])
        #expect(options[.applicationVersion] as? String == "0.7.0")
        let credits = try #require(options[.credits] as? NSAttributedString)
        #expect(credits.string == "Bundled daemon: tabghostty-477813d-dirty")
    }

    // `swift run`（Info.plist が無い）や、記録の無い古いバンドル: バージョンは AppKit の既定に任せ、デーモンは none。
    @Test func missingValuesFallBackWithoutAnEmptyVersion() throws {
        for info: [String: Any] in [[:], ["CFBundleShortVersionString": "", "TabghosttyDaemonRevision": ""]] {
            let options = AboutPanel.options(info: info)
            #expect(options[.applicationVersion] == nil)
            let credits = try #require(options[.credits] as? NSAttributedString)
            #expect(credits.string == "Bundled daemon: none")
        }
    }
}

/// spec: terminal-search「Find bar」「Match navigation」— Edit メニューの検索。
@MainActor
@Suite struct FindMenuTests {
    @Test func editMenuHasFindItems() throws {
        let menu = AppMenu.make()
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let find = try #require(edit.items.first { $0.action == #selector(TerminalFindActions.showFindBar(_:)) })
        #expect(find.keyEquivalent == "f" && find.keyEquivalentModifierMask == .command && find.target == nil)
        let next = try #require(edit.items.first { $0.action == #selector(TerminalFindActions.findNext(_:)) })
        #expect(next.keyEquivalent == "g" && next.keyEquivalentModifierMask == .command)
        let previous = try #require(edit.items.first { $0.action == #selector(TerminalFindActions.findPrevious(_:)) })
        #expect(previous.keyEquivalent == "g" && previous.keyEquivalentModifierMask == [.command, .shift])
    }
}
