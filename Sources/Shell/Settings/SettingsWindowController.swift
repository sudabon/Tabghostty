import AppKit
import DaemonClient
import DesktopSupport

/// 設定画面（spec: settings-window「Settings window layout」、phase4 design D3）。
///
/// サイドバーの「設定」と Command-, で開く 1 つのウィンドウ。カテゴリは「外観」「一般」「通知」「キーボード」の順で、
/// 開くたびに「外観」を選ぶ（Web 版と同じ）。保存ボタンは無く、変更のたびに `PATCH /api/config` で保存する。
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let contentSize = NSSize(width: 560, height: 520)

    let tabs = NSTabViewController()
    let appearancePane: AppearancePaneController
    let generalPane: GeneralPaneController
    let notificationsPane: NotificationsPaneController
    let keyboardPane: KeyboardPaneController

    public init(
        config: ConfigStore,
        editor: ConfigEditor,
        notifications: any NativeNotificationServicing,
        theme: ResolvedTheme
    ) {
        appearancePane = AppearancePaneController(config: config, editor: editor)
        generalPane = GeneralPaneController(config: config, editor: editor)
        notificationsPane = NotificationsPaneController(config: config, editor: editor, service: notifications)
        keyboardPane = KeyboardPaneController(config: config, editor: editor)

        let window = SettingsWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "設定"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self

        tabs.tabStyle = .toolbar
        let items: [(NSViewController, String)] = [
            (appearancePane, "paintpalette"),
            (generalPane, "gearshape"),
            (notificationsPane, "bell.badge"),
            (keyboardPane, "keyboard"),
        ]
        for (pane, symbol) in items {
            let item = NSTabViewItem(viewController: pane)
            item.label = pane.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.setContentSize(Self.contentSize)
        applyTheme(theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// カテゴリの名前（表示の順）。
    var categoryTitles: [String] {
        tabs.tabViewItems.map(\.label)
    }

    /// 選んでいるカテゴリ。
    var selectedCategory: String? {
        let index = tabs.selectedTabViewItemIndex
        return tabs.tabViewItems.indices.contains(index) ? tabs.tabViewItems[index].label : nil
    }

    /// 「外観」を選んで開く。通知の許可の表示を更新する。
    public func present(makeKey: Bool = true) {
        tabs.selectedTabViewItemIndex = 0
        if window?.isVisible != true {
            window?.center()
        }
        if makeKey {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        }
        refreshNotificationPermission()
    }

    /// 通知の許可の状態を読み直す（開いたとき、アプリが前面に来たとき）。
    public func refreshNotificationPermission() {
        let pane = notificationsPane
        pane.loadViewIfNeeded()
        Task { await pane.refreshPermission() }
    }

    /// 配色に外観を合わせる。
    public func applyTheme(_ theme: ResolvedTheme) {
        window?.appearance = theme.appearance
    }

    public func windowWillClose(_ notification: Notification) {
        keyboardPane.cancelRecording()
    }

    public func windowDidResignKey(_ notification: Notification) {
        keyboardPane.cancelRecording()
    }
}

/// Command-W で閉じる設定画面のウィンドウ（メインメニューに「閉じる」が無いため）。
@MainActor
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
