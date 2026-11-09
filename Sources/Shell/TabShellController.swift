import AppKit
import DaemonClient
import DesktopSupport
import TerminalCore
import TerminalUI

/// サイドバー・端末・未読・コード・タブの操作をつなぐ（webtabinal `App.tsx` に当たる）。
///
/// - タブの一覧は、デーモンの `sessions` でだけ変わる（作る・複製・再起動は、返ってきたセッションをアクティブにするだけ）。
/// - タブの選択・新規作成・サイドバーの開閉のあとは、端末にキーボードフォーカスを戻す。
/// - 未読は `UnreadTracker`、Dock のバッジは未読の数（spec: tab-sidebar「Unread dots and Dock badge」）。
///   未読にするか・通知を出すかは `NotificationCoordinator` が決める（spec: notifications）。
/// - セッションが 1 件以上から 0 件になったら、`quit_when_no_tabs` に従って終了するか、空の画面を出す。
/// - 設定は `ConfigStore` から読み、変わったら再起動せずに反映する（phase4 design D4 の表）。
@MainActor
public final class TabShellController {
    public let coordinator: SessionCoordinator
    public let terminalView: TerminalView
    public let sidebar: SidebarViewController
    public let terminalArea: TerminalAreaViewController
    public let splitViewController: ShellSplitViewController
    public let unread = UnreadTracker()
    public let chord: ChordController
    public let config: ConfigStore
    public let editor: ConfigEditor
    public let appearance: AppearanceController
    public let notifications: NotificationCoordinator
    public let imageAttach: ImageAttachService?
    /// サイドバーなど周りの UI の配色（配色を切り替えると変わる）。
    public private(set) var palette: ChromePalette {
        didSet { applyChromePalette() }
    }

    /// タブとサイドバーの設定（参照のたびに `ConfigStore` から読む）。
    public var settings: TabSettings { config.settings.tabs }

    private let dockBadge: DockBadge
    private var previousSessionCount: Int?
    private var memoEditor: MemoEditorSheet?
    private var windowObservers: [NSObjectProtocol] = []
    private var didReportSessionsReady = false

    /// タブが 0 件になり、`quit_when_no_tabs` が有効（アプリを終了する。デーモンは残す）。
    public var onQuitRequested: (() -> Void)?
    /// サイドバーの幅をドラッグで変えた（`PATCH /api/config` で保存する）。
    public var onSidebarWidthCommitted: ((Int) -> Void)?
    /// 一覧かアクティブセッションが変わった（ウィンドウのタイトルを変える）。
    public var onStoreChange: (() -> Void)?
    /// コードの保留中の表示（nil なら隠す）。
    public var onPendingChordChange: ((String?) -> Void)?
    /// 実行中のタブを閉じる前に確かめる（テストで差し替える）。nil なら確認のシートを出す。
    public var confirmClose: ((SessionInfo, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// サイドバーの「設定」を押した。
    public var onOpenSettings: (() -> Void)?
    /// 配色が変わった（ウィンドウの背景と外観、コードの表示、設定画面に配る）。
    public var onThemeChange: ((ResolvedTheme) -> Void)?
    /// 一時的に知らせるメッセージ（設定の保存に失敗した、など）。
    public var onTransientMessage: ((String) -> Void)?
    /// 起動後、最初のセッション一覧を受け取った（通知のクリックでタブを選べるようになった）。
    public var onSessionsReady: (() -> Void)?

    /// - Parameters:
    ///   - notificationService: 通知を出すもの。nil なら通知を出さない（未読とバッジは付く）
    ///   - imageUploader: 画像のアップロード。nil なら画像を添付しない
    public init(
        coordinator: SessionCoordinator,
        terminalView: TerminalView,
        config: ConfigStore,
        editor: ConfigEditor,
        appearance: AppearanceController,
        notificationService: (any NativeNotificationServicing)?,
        imageUploader: (any ImageUploadAPI)?,
        dockTile: any DockBadging
    ) {
        self.coordinator = coordinator
        self.terminalView = terminalView
        self.config = config
        self.editor = editor
        self.appearance = appearance
        palette = appearance.theme.chrome
        dockBadge = DockBadge(tile: dockTile)
        sidebar = SidebarViewController(palette: palette)
        terminalArea = TerminalAreaViewController(terminalView: terminalView, palette: palette)
        splitViewController = ShellSplitViewController(
            sidebar: sidebar, terminalArea: terminalArea, sidebarWidth: config.settings.tabs.sidebarWidth
        )
        chord = ChordController(bindings: config.settings.tabs.keyBindings)
        notifications = NotificationCoordinator(
            store: coordinator.store,
            settings: { [weak config] in config?.settings.tabs.notification ?? NotificationSettings() },
            unread: unread,
            service: notificationService
        )
        imageAttach = imageUploader.map { uploader in
            ImageAttachService(store: coordinator.store, uploader: uploader) { [weak terminalView] text in
                terminalView?.pasteText(text)
            }
        }
        let display = config.settings.display
        terminalView.inputSettings.shiftEnterNewline = display.shiftEnterNewline
        terminalView.inputSettings.copyOnSelect = display.copyOnSelect
        terminalView.dropHighlightColor = palette.accent.nsColor
        wire()
        observeConfig()
        refresh()
    }

    isolated deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func wire() {
        sidebar.onSelect = { [weak self] id in self?.select(id) }
        sidebar.onEditMemo = { [weak self] id in self?.editMemo(id) }
        sidebar.onNewTab = { [weak self] in self?.createTab() }
        sidebar.onReorder = { [weak self] ids in self?.reorder(ids) }
        sidebar.onMenuAction = { [weak self] id, action in self?.perform(action, on: id) }
        sidebar.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        terminalArea.onNewTab = { [weak self] in self?.createTab() }
        splitViewController.onSidebarWidthCommitted = { [weak self] width in self?.commitSidebarWidth(width) }
        splitViewController.onSidebarToggled = { [weak self] in self?.focusTerminal() }

        chord.isSuspended = { [weak self] in self?.isModalOpen ?? false }
        chord.onAction = { [weak self] action in self?.performChord(action) }
        chord.onPendingChange = { [weak self] pending in
            guard let self else { return }
            self.onPendingChordChange?(pending ? self.chord.pendingIndicatorText : nil)
        }
        terminalView.keyChordHandler = { [weak self] stroke in
            self?.chord.handle(stroke) ?? false
        }
        if imageAttach != nil {
            terminalView.imageAttachHandler = { [weak self] images in
                guard let self, let imageAttach = self.imageAttach else { return }
                Task { await imageAttach.attach(images) }
            }
        }

        notifications.isWindowFocused = { [weak self] in
            self?.terminalView.window?.isKeyWindow ?? false
        }
        coordinator.onActiveControllerChange = { [weak self] controller in
            self?.terminalView.controller = controller
        }
        coordinator.store.onChange = { [weak self] in self?.storeDidChange() }
        coordinator.store.onEvent = { [weak self] event in self?.notifications.handle(event) }
        unread.onChange = { [weak self] in self?.refresh() }
        appearance.onChange = { [weak self] theme in self?.applyTheme(theme) }
    }

    // MARK: - 設定の反映（phase4 design D4）

    private func observeConfig() {
        config.observe([.colorScheme]) { [weak self] settings, _ in
            self?.appearance.scheme = settings.display.colorScheme
        }
        config.observe([.fontFamily, .fontSize]) { [weak self] settings, _ in
            self?.terminalView.setFont(family: settings.display.fontFamily, size: CGFloat(settings.display.fontSize))
        }
        config.observe([.shiftEnterNewline, .copyOnSelect]) { [weak self] settings, _ in
            self?.terminalView.inputSettings.shiftEnterNewline = settings.display.shiftEnterNewline
            self?.terminalView.inputSettings.copyOnSelect = settings.display.copyOnSelect
        }
        config.observe([.keyBindings]) { [weak self] settings, _ in
            self?.chord.bindings = settings.tabs.keyBindings
        }
        config.observe([.sidebarWidth]) { [weak self] settings, _ in
            self?.splitViewController.applyConfiguredWidth(settings.tabs.sidebarWidth)
        }
        config.observe([.scrollbackLines]) { [weak self] settings, _ in
            guard let self else { return }
            let lines = settings.display.scrollbackLines
            for controller in self.coordinator.allControllers {
                Task { await controller.setMaxScrollback(lines) }
            }
        }
    }

    /// 配色を切り替える（spec: color-scheme「Scheme applies everywhere」）。
    private func applyTheme(_ theme: ResolvedTheme) {
        terminalView.setPalette(theme.palette)
        let colors = theme.palette.terminalColors
        for controller in coordinator.allControllers {
            Task { await controller.setColors(colors) }
        }
        palette = theme.chrome
        onThemeChange?(theme)
    }

    private func applyChromePalette() {
        sidebar.palette = palette
        terminalArea.palette = palette
        splitViewController.applyPalette(palette)
        terminalView.dropHighlightColor = palette.accent.nsColor
        terminalView.window?.backgroundColor = palette.background.nsColor
    }

    private func commitSidebarWidth(_ width: Int) {
        onSidebarWidthCommitted?(width)
        Task {
            do {
                try await editor.apply(ConfigPatch(sidebarWidth: width))
            } catch {
                onTransientMessage?(ConfigEditor.message(for: error))
            }
        }
    }

    /// メインウィンドウに載せた。ウィンドウがフォーカスを失ったときと、シートを開いたときに、保留中のコードを取り消す。
    public func attach(to window: NSWindow) {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = [NSWindow.didResignKeyNotification, NSWindow.willBeginSheetNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chord.cancel() }
            }
        }
    }

    /// 開いているメモの編集シート（テスト用）。
    var activeMemoEditor: MemoEditorSheet? { memoEditor }

    /// メモの編集シートや確認のシートを開いている。
    private var isModalOpen: Bool {
        memoEditor != nil || terminalView.window?.attachedSheet != nil
    }

    // MARK: - 一覧の変化

    private func storeDidChange() {
        let store = coordinator.store
        // 一覧から消えたセッションは未読から取り除く（`unread.onChange` で表示も変わる）。
        unread.retain(only: store.sessions.map(\.id))
        refresh()
        applyLastTabPolicy()
        onStoreChange?()
        if store.hasReceivedSessions, !didReportSessionsReady {
            didReportSessionsReady = true
            onSessionsReady?()
        }
    }

    private func refresh() {
        let store = coordinator.store
        sidebar.update(sessions: store.sessions, activeID: store.activeSessionID, unread: unread.unreadIDs)
        dockBadge.update(count: unread.count)
    }

    private func applyLastTabPolicy() {
        let store = coordinator.store
        guard store.hasReceivedSessions else { return }
        let count = store.sessions.count
        switch TabPolicy.lastTabOutcome(previousCount: previousSessionCount, currentCount: count, quitWhenNoTabs: settings.quitWhenNoTabs) {
        case .quit:
            onQuitRequested?()
        case .showEmptyState:
            terminalArea.isEmptyStateVisible = true
        case .none:
            break
        }
        if count > 0 {
            terminalArea.isEmptyStateVisible = false
        }
        previousSessionCount = count
    }

    // MARK: - タブの操作（spec: tab-operations）

    /// タブを選ぶ: アクティブにし（replay しない）、未読を消し、端末にフォーカスを移す。
    public func select(_ id: String) {
        guard coordinator.store.sessions.contains(where: { $0.id == id }) else { return }
        coordinator.activate(id)
        unread.markRead(id)
        focusTerminal()
    }

    /// その位置（1 から）のタブを選ぶ。無ければ何もしない。選んだら true。
    @discardableResult
    public func selectTab(atPosition position: Int) -> Bool {
        guard canSelectTab(atPosition: position) else { return false }
        select(coordinator.store.sessions[position - 1].id)
        return true
    }

    /// その位置（1 から）にタブがあるか。
    public func canSelectTab(atPosition position: Int) -> Bool {
        position >= 1 && position <= coordinator.store.sessions.count
    }

    /// 新しいタブをホームディレクトリで作り、アクティブにして端末にフォーカスを移す。
    public func createTab() {
        focusTerminal()
        Task {
            await coordinator.createSession()
            focusTerminal()
        }
    }

    public func duplicate(_ id: String) {
        Task {
            await coordinator.duplicateSession(id)
            focusTerminal()
        }
    }

    /// 終了済みのタブを再起動する（終了していなければ何もしない）。
    public func restart(_ id: String) {
        Task {
            await coordinator.restartSession(id)
            focusTerminal()
        }
    }

    /// タブを閉じる。`confirm_close_running` が有効で実行中なら、先に確かめる。
    public func requestClose(_ id: String) {
        guard let session = coordinator.store.sessions.first(where: { $0.id == id }) else { return }
        guard TabPolicy.needsCloseConfirmation(session, confirmCloseRunning: settings.confirmCloseRunning) else {
            Task { await coordinator.closeSession(id) }
            return
        }
        let close: @MainActor (Bool) -> Void = { [weak self] confirmed in
            guard confirmed, let self else { return }
            Task { await self.coordinator.closeSession(id) }
        }
        if let confirmClose {
            confirmClose(session, close)
        } else {
            presentCloseConfirmation(close)
        }
    }

    private func presentCloseConfirmation(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard let window = terminalView.window else {
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = TabPolicy.closeConfirmationMessage
        alert.addButton(withTitle: "閉じる")
        let cancel = alert.addButton(withTitle: "キャンセル")
        cancel.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                completion(response == .alertFirstButtonReturn)
                self?.focusTerminal()
            }
        }
    }

    /// ダブルクリック: タブをアクティブにして、メモの編集シートを開く。
    public func editMemo(_ id: String) {
        guard memoEditor == nil, let session = coordinator.store.sessions.first(where: { $0.id == id }) else { return }
        select(id)
        guard let window = terminalView.window else { return }
        chord.cancel()
        let editor = MemoEditorSheet(initialMemo: session.memo, palette: palette) { [weak self] memo in
            guard let self else { return }
            try await self.coordinator.updateMemo(id, memo: memo)
        }
        memoEditor = editor
        sidebar.isMemoEditorOpen = true
        editor.begin(for: window) { [weak self] in
            guard let self else { return }
            self.memoEditor = nil
            self.sidebar.isMemoEditorOpen = false
            self.focusTerminal()
        }
    }

    public func toggleNotificationsMuted(_ id: String) {
        Task { await coordinator.toggleNotificationsMuted(id) }
    }

    public func reorder(_ ids: [String]) {
        Task { await coordinator.reorderSessions(ids) }
    }

    /// 右クリックメニューの項目。
    public func perform(_ action: TabMenuItemState.Action, on id: String) {
        switch action {
        case .duplicate: duplicate(id)
        case .restart: restart(id)
        case .close: requestClose(id)
        case .toggleNotifications: toggleNotificationsMuted(id)
        }
    }

    // MARK: - サイドバーとコード

    /// サイドバーを隠す・表示する（状態は保存しない）。切り替えたら端末にフォーカスを戻す。
    public func toggleSidebar(animated: Bool = true) {
        splitViewController.toggleSidebarVisibility(animated: animated)
    }

    private func performChord(_ action: ChordAction) {
        switch action {
        case .toggleSidebar:
            toggleSidebar()
        case .next, .prev:
            let sessions = coordinator.store.sessions
            let activeIndex = sessions.firstIndex { $0.id == coordinator.store.activeSessionID } ?? -1
            let index = Keymap.neighbourTabIndex(count: sessions.count, activeIndex: activeIndex, direction: action == .next ? .next : .prev)
            if index >= 0 {
                select(sessions[index].id)
            }
        case .none, .arm, .cancel:
            break
        }
    }

    /// 端末にキーボードフォーカスを移す（シートを開いているときは、閉じたときに移す）。
    public func focusTerminal() {
        guard let window = terminalView.window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(terminalView)
    }
}
