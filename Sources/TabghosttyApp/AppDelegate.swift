import AppKit
import DaemonClient
import DesktopSupport
import Shell
import TerminalCore
import TerminalUI
import UserNotifications

/// アプリ全体（spec: app-shell）。
///
/// 起動の手順: config.json を読む → デーモンを検出（無ければ同梱のものを起動）→ トークンを読む →
/// `GET /api/config` で設定を読む → WebSocket で接続し、サイドバーとアクティブセッションを表示する。
/// どこかで失敗したら、エラー文と再試行ボタンを出す。ウィンドウを閉じるとアプリは終了するが、デーモンは残す。
///
/// 設定は `ConfigStore` に置き、アプリが前面に来たとき・設定画面を開いたとき・再接続したときに読み直す
/// （phase4 design D4）。通知のクリックは `NotificationActivationCoordinator` でタブの選択につなぐ（design D2）。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, TabMenuActions, AppMenuActions {
    private var windowController: MainWindowController?
    private var coordinator: SessionCoordinator?
    private var shell: TabShellController?
    private var settingsWindow: SettingsWindowController?
    private var startupTask: Task<Void, Never>?
    /// 接続が切れている間、デーモンが止まっていないかを確かめる。
    private var connectionWatchTask: Task<Void, Never>?
    /// 接続が切れてから、デーモンが待ち受けているかを確かめるまでの間隔。
    static let connectionWatchInterval: Duration = .seconds(3)
    private var appObservers: [NSObjectProtocol] = []
    /// 通知（`.app` として起動していなければ、何も出さないもの）。
    private let notificationService = NativeNotificationService.forCurrentProcess()
    /// 通知のクリックで選ぶタブ（セッション一覧を受け取るまで保留する）。
    private let activation = NotificationActivationCoordinator()

    public override init() {
        super.init()
    }

    /// アプリを起動する。
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .app にしていない（`swift run`）ときも、Dock とメニューバーに出す。
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.make()
        // 通知のクリックでアプリが起動したときにも受け取れるよう、起動を終える前に delegate にする。
        // `UNUserNotificationCenter` はバンドルの外では使えない（落ちる）。
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        })
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // libghostty-vt のプロセス全体の設定（PNG の展開）は、ほかのスレッドがライブラリを使う前に済ませる。
        GhosttySystem.install()
        // Metal のシェーダーは実行時にコンパイルする（数十 ms）。デーモンにつなぐ間に済ませておく（phase5 design D1）。
        TerminalView.preloadRenderer()
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()
        startup()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最後のウィンドウ（メインウィンドウ）を閉じたら終了する。デーモンとセッションは止めない。
        true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// アプリが前面に来た: ブラウザ版で変えた設定を拾い、設定画面の通知の許可の表示を更新する。
    private func applicationDidBecomeActive() {
        guard let shell else { return }
        Task { await shell.config.reload() }
        settingsWindow?.refreshNotificationPermission()
    }

    // MARK: - 起動

    private func startup() {
        startupTask?.cancel()
        connectionWatchTask?.cancel()
        connectionWatchTask = nil
        let previous = coordinator
        coordinator = nil
        shell = nil
        settingsWindow?.close()
        settingsWindow = nil
        activation.markNotReady()
        NSApp.dockTile.badgeLabel = nil
        windowController?.showConnecting()
        startupTask = Task { [weak self] in
            await previous?.stop()
            guard let self else { return }
            do {
                try await self.connect()
            } catch is CancellationError {
                return
            } catch {
                // エラー文にはトークンを含めない（DaemonConfigError / DaemonLaunchError / RESTError が保証する）。
                self.windowController?.showStartupFailure(error.localizedDescription) { [weak self] in
                    self?.startup()
                }
            }
        }
    }

    private func connect() async throws {
        let initial = try DaemonConfig.load()
        try await DaemonLauncher(port: initial.port).ensureRunning()
        try Task.checkCancellation()

        // デーモンを初めて起動したときは、トークンがこの時点で書き込まれる。
        let daemonConfig = try DaemonConfig.load()
        let token = try daemonConfig.requireAuthToken()
        let rest = RESTClient(port: daemonConfig.port, token: token)
        let settings = try await rest.fetchSettings()
        try Task.checkCancellation()

        let config = ConfigStore(settings: settings, api: rest)
        let editor = ConfigEditor(store: config, api: rest)
        let appearance = AppearanceController(scheme: settings.display.colorScheme)
        let display = settings.display
        let terminalView = TerminalView(
            fontFamily: display.fontFamily, fontSize: CGFloat(display.fontSize), palette: appearance.theme.palette
        )
        let clipboard = PasteboardClipboard()

        // 新しく作る端末には、その時点の `scrollback_lines` と配色を使う。
        let coordinator = SessionCoordinator(
            connection: WSConnection(port: daemonConfig.port, token: token),
            api: rest
        ) { [weak terminalView, weak config, weak appearance] sid, sink in
            let grid = terminalView?.appliedGrid
            return try TerminalController(
                sid: sid,
                cols: grid?.cols ?? 80,
                rows: grid?.rows ?? 24,
                maxScrollback: config?.settings.display.scrollbackLines ?? display.scrollbackLines,
                colors: (appearance?.theme.palette ?? Palette.dark).terminalColors,
                sink: sink,
                clipboard: clipboard
            )
        }
        let shell = TabShellController(
            coordinator: coordinator,
            terminalView: terminalView,
            config: config,
            editor: editor,
            appearance: appearance,
            notificationService: notificationService,
            imageUploader: rest,
            dockTile: NSApp.dockTile
        )
        wire(coordinator, shell: shell, terminalView: terminalView)
        self.coordinator = coordinator
        self.shell = shell
        windowController?.showShell(shell)
        await coordinator.start()
    }

    private func wire(_ coordinator: SessionCoordinator, shell: TabShellController, terminalView: TerminalView) {
        terminalView.onGridChange = { [weak coordinator] grid in
            coordinator?.viewGrid = grid
        }
        terminalView.onFocus = { [weak coordinator] in
            // 複数のクライアントがいると PTY のサイズは最後の resize になるので、フォーカスを得たら送り直す。
            guard let controller = coordinator?.activeController else { return }
            Task { await controller.resendViewSize() }
        }
        coordinator.onTransientMessage = { [weak self] message in
            self?.windowController?.showToast(message)
        }
        var everConnected = false
        let port = coordinator.connection.port
        coordinator.onConnectionChange = { [weak self, weak shell] connected in
            shell?.connectionDidChange(connected: connected)
            self?.connectionDidChange(connected, port: port)
            guard connected else { return }
            // 再接続したら設定を読み直す（切れている間にブラウザ版で変えたかもしれない）。
            if everConnected, let shell {
                Task { await shell.config.reload() }
            }
            everConnected = true
        }
        coordinator.onConnectionRejected = { [weak self] status in
            self?.connectionWasRejected(status: status)
        }
        shell.onTransientMessage = { [weak self] message in
            self?.windowController?.showToast(message)
        }
        shell.onStoreChange = { [weak self, weak coordinator] in
            guard let coordinator else { return }
            self?.windowController?.updateTitle(cwd: coordinator.store.activeSession?.cwd)
        }
        shell.onPendingChordChange = { [weak self] text in
            self?.windowController?.showChordIndicator(text)
        }
        shell.onThemeChange = { [weak self] theme in
            self?.windowController?.applyTheme(theme)
            self?.settingsWindow?.applyTheme(theme)
        }
        shell.onOpenSettings = { [weak self] in
            self?.openSettings(nil)
        }
        shell.onSessionsReady = { [weak self] in
            self?.activation.markReady { sid in self?.shell?.select(sid) }
        }
        shell.onQuitRequested = {
            // 最後のタブを閉じたら終了する。デーモンとセッションは止めない。
            NSApp.terminate(nil)
        }
        if let grid = terminalView.appliedGrid {
            coordinator.viewGrid = grid
        }
    }

    // MARK: - 接続が切れたとき

    /// 切れたら帯を出し、つながったら消す。切れている間は、デーモンが待ち受けているかを確かめ、
    /// 止まっている・ほかのプログラムがポートを使っているなら、ボタンを出す（押すと、起動の手順をやり直す）。
    private func connectionDidChange(_ connected: Bool, port: Int) {
        connectionWatchTask?.cancel()
        connectionWatchTask = nil
        guard !connected else {
            windowController?.hideConnectionLost()
            return
        }
        let restart: () -> Void = { [weak self] in self?.startup() }
        windowController?.showConnectionLost(.reconnecting, onAction: restart)
        connectionWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.connectionWatchInterval)
                guard !Task.isCancelled else { return }
                // プローブは送受信ごとに 300 ms のタイムアウトで同期的にブロックするので、メインスレッドの外で行う。
                let result = await Task.detached { probeWebTabinal(port: port) }.value
                guard !Task.isCancelled else { return }
                self?.windowController?.showConnectionLost(ConnectionLostReason(probe: result, port: port), onAction: restart)
            }
        }
    }

    /// デーモンがトークンを拒否した: 再接続しても通らないので、プローブをやめ、config.json を読み直してつなぎ直すボタンを出す。
    private func connectionWasRejected(status: Int) {
        connectionWatchTask?.cancel()
        connectionWatchTask = nil
        windowController?.showConnectionLost(.rejected(status: status)) { [weak self] in self?.startup() }
    }

    // MARK: - 通知のクリック（spec: notifications「Delivery and activation」、phase4 design D2）

    /// 通知がクリックされた: アプリを前面に出してウィンドウを見せ、そのセッションがまだあれば選ぶ。
    /// セッション一覧を受け取る前なら、受け取ってから選ぶ。
    func activate(fromNotificationFor sid: String?) {
        NSApp.activate()
        if let window = windowController?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        guard let sid else { return }
        activation.receive(sessionID: sid) { [weak self] sid in
            self?.shell?.select(sid)
        }
    }

    // MARK: - 設定画面（spec: settings-window）

    /// 設定画面を開く（Command-, とサイドバーの「設定」）。開くたびに「外観」を選び、設定を読み直す。
    @objc public func openSettings(_ sender: Any?) {
        guard let shell else { return }
        let controller = settingsWindow ?? SettingsWindowController(
            config: shell.config,
            editor: shell.editor,
            notifications: notificationService,
            theme: shell.appearance.theme
        )
        settingsWindow = controller
        controller.present()
        let config = shell.config
        Task { [weak controller] in
            // 読めなかったら、表示している値が古いかもしれないことを知らせる。
            if await !config.reload(), let message = config.reloadError {
                controller?.showReloadFailure(message)
            }
        }
    }

    // MARK: - About（spec: app-shell「Version information in About」）

    /// About パネルを出す。接続する前（起動失敗の画面）でも開ける。
    @objc public func showAboutPanel(_ sender: Any?) {
        AboutPanel.show()
    }

    // MARK: - メニューの操作（spec: keyboard-shortcuts「Command shortcuts」、tab-sidebar「Sidebar collapse」）

    @objc public func newTab(_ sender: Any?) {
        shell?.createTab()
    }

    @objc public func selectTabFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        // 無い位置なら何もしない。
        shell?.selectTab(atPosition: item.tag)
    }

    @objc public func toggleTabSidebar(_ sender: Any?) {
        shell?.toggleSidebar()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newTab(_:)), #selector(toggleTabSidebar(_:)), #selector(openSettings(_:)):
            return shell != nil
        case #selector(selectTabFromMenu(_:)):
            return shell?.canSelectTab(atPosition: menuItem.tag) ?? false
        default:
            return true
        }
    }
}

/// メニューから送るタブの操作（target を nil にして、レスポンダチェーンの `AppDelegate` に届ける）。
@MainActor
@objc protocol TabMenuActions {
    func newTab(_ sender: Any?)
    func selectTabFromMenu(_ sender: Any?)
    func toggleTabSidebar(_ sender: Any?)
    func openSettings(_ sender: Any?)
}

/// アプリメニューから送る操作（target を nil にして、レスポンダチェーンの `AppDelegate` に届ける）。
@MainActor
@objc protocol AppMenuActions {
    func showAboutPanel(_ sender: Any?)
}

/// アプリメニュー（spec: app-shell「Application menu」）。
@MainActor
enum AppMenu {
    static func make() -> NSMenu {
        let appName = WindowTitle.appName
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: appName)
        appItem.submenu = appMenu

        // About パネル（spec: app-shell「Version information in About」）。バージョンと同梱のデーモンを出す。
        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(AppMenuActions.showAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        // 設定画面（spec: settings-window「Settings window layout」）。
        appMenu.addItem(withTitle: "設定…", action: #selector(TabMenuActions.openSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        mainMenu.addItem(makeFileItem())
        mainMenu.addItem(makeEditItem())
        mainMenu.addItem(makeViewItem())
        mainMenu.addItem(makeWindowItem())
        return mainMenu
    }

    /// File メニュー（Command-N で新しいタブ）。
    static func makeFileItem() -> NSMenuItem {
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "新規タブ", action: #selector(TabMenuActions.newTab(_:)), keyEquivalent: "n")
        return fileItem
    }

    /// View メニュー（サイドバーの表示・非表示。キー等価物なし）。
    static func makeViewItem() -> NSMenuItem {
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "サイドバーを表示/隠す", action: #selector(TabMenuActions.toggleTabSidebar(_:)), keyEquivalent: "")
        return viewItem
    }

    /// Window メニュー（Command-1〜9 で、その位置のタブを選ぶ）。
    static func makeWindowItem() -> NSMenuItem {
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        for position in 1...9 {
            let item = windowMenu.addItem(
                withTitle: "タブ \(position)",
                action: #selector(TabMenuActions.selectTabFromMenu(_:)),
                keyEquivalent: String(position)
            )
            item.tag = position
        }
        return windowItem
    }

    /// Edit メニュー（spec: terminal-clipboard「Edit menu」）。
    ///
    /// target を nil にして first responder に送る。端末にフォーカスがあれば `TerminalView` の copy / paste、
    /// テキストフィールドにフォーカスがあれば、フィールドの標準のコピーとペーストになる。
    static func makeEditItem() -> NSMenuItem {
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        // テキストフィールド（メモ・設定）の標準の編集操作。テキストフィールドは、メニューの項目が無いとこれらのキーを受けない。
        // 端末にフォーカスがあるときは、端末が実装していないので無効になる（キーはセッションに送らない）。
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // 端末の中の検索（spec: terminal-search）。検索欄にフォーカスがあっても、レスポンダチェーンで端末に届く。
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "検索…", action: #selector(TerminalFindActions.showFindBar(_:)), keyEquivalent: "f")
        editMenu.addItem(withTitle: "次を検索", action: #selector(TerminalFindActions.findNext(_:)), keyEquivalent: "g")
        let previous = editMenu.addItem(
            withTitle: "前を検索", action: #selector(TerminalFindActions.findPrevious(_:)), keyEquivalent: "g"
        )
        previous.keyEquivalentModifierMask = [.command, .shift]
        return editItem
    }
}


// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// アプリが前面にあるときも、バナーと通知センターに出す。
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        foregroundNotificationPresentationOptions()
    }

    /// 通知をクリックした。
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sid = response.notification.request.content.userInfo["sid"] as? String
        await MainActor.run {
            self.activate(fromNotificationFor: sid)
        }
    }
}
