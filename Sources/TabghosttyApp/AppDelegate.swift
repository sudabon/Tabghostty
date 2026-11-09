import AppKit
import DaemonClient
import TerminalCore
import TerminalUI

/// アプリ全体（spec: app-shell）。
///
/// 起動の手順: config.json を読む → デーモンを検出（無ければ同梱のものを起動）→ トークンを読む →
/// `GET /api/config` で表示の設定を読む → WebSocket で接続し、アクティブセッションを表示する。
/// どこかで失敗したら、エラー文と再試行ボタンを出す。ウィンドウを閉じるとアプリは終了するが、デーモンは残す。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var coordinator: SessionCoordinator?
    private var startupTask: Task<Void, Never>?

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
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController()
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()
        startup()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 最後のウィンドウを閉じたら終了する。デーモンとセッションは止めない。
        true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - 起動

    private func startup() {
        startupTask?.cancel()
        let previous = coordinator
        coordinator = nil
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
        let config = try DaemonConfig.load()
        let token = try config.requireAuthToken()
        let rest = RESTClient(port: config.port, token: token)
        let display = try await rest.fetchDisplaySettings()
        try Task.checkCancellation()

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // 配色は起動時に決めて固定する（設定や system の変化への追従は Phase 4）。
        let palette = Palette.resolve(colorScheme: display.colorScheme.rawValue, systemIsDark: isDark)
        let terminalView = TerminalView(fontFamily: display.fontFamily, fontSize: CGFloat(display.fontSize), palette: palette)

        let scrollback = display.scrollbackLines
        let colors = palette.terminalColors
        let coordinator = SessionCoordinator(
            connection: WSConnection(port: config.port, token: token),
            api: rest
        ) { [weak terminalView] sid, sink in
            let grid = terminalView?.appliedGrid
            return try TerminalController(
                sid: sid,
                cols: grid?.cols ?? 80,
                rows: grid?.rows ?? 24,
                maxScrollback: scrollback,
                colors: colors,
                sink: sink
            )
        }
        wire(coordinator, to: terminalView)
        self.coordinator = coordinator
        windowController?.showTerminal(terminalView, background: palette.background)
        await coordinator.start()
    }

    private func wire(_ coordinator: SessionCoordinator, to terminalView: TerminalView) {
        terminalView.onGridChange = { [weak coordinator] grid in
            coordinator?.viewGrid = grid
        }
        terminalView.onFocus = { [weak coordinator] in
            // 複数のクライアントがいると PTY のサイズは最後の resize になるので、フォーカスを得たら送り直す。
            guard let controller = coordinator?.activeController else { return }
            Task { await controller.resendViewSize() }
        }
        coordinator.onActiveControllerChange = { [weak terminalView] controller in
            terminalView?.controller = controller
        }
        coordinator.onTransientMessage = { [weak self] message in
            self?.windowController?.showToast(message)
        }
        coordinator.store.onChange = { [weak self, weak coordinator] in
            guard let coordinator else { return }
            self?.windowController?.updateTitle(cwd: coordinator.store.activeSession?.cwd)
        }
        if let grid = terminalView.appliedGrid {
            coordinator.viewGrid = grid
        }
    }
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

        appMenu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
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
        return mainMenu
    }
}
