import Foundation

/// `key_bindings` の設定（プレフィックスによるコード。spec: keyboard-shortcuts）。
public struct KeyBindings: Equatable, Sendable, Encodable {
    public static let `default` = KeyBindings()

    /// 既定は無効。
    public var enabled = false
    public var prefix = "ctrl+j"
    public var nextTab = "n"
    public var prevTab = "p"
    public var toggleSidebar = "j"

    public init(
        enabled: Bool = false,
        prefix: String = "ctrl+j",
        nextTab: String = "n",
        prevTab: String = "p",
        toggleSidebar: String = "j"
    ) {
        self.enabled = enabled
        self.prefix = prefix
        self.nextTab = nextTab
        self.prevTab = prevTab
        self.toggleSidebar = toggleSidebar
    }

    /// JSON のオブジェクトから読む。空の文字列はデーモンと同じく既定値にする。
    init(json: [String: Any]) {
        if let value = DisplaySettings.bool(json["enabled"]) { enabled = value }
        if let value = json["prefix"] as? String, !value.isEmpty { prefix = value }
        if let value = json["next_tab"] as? String, !value.isEmpty { nextTab = value }
        if let value = json["prev_tab"] as? String, !value.isEmpty { prevTab = value }
        if let value = json["toggle_sidebar"] as? String, !value.isEmpty { toggleSidebar = value }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, prefix
        case nextTab = "next_tab"
        case prevTab = "prev_tab"
        case toggleSidebar = "toggle_sidebar"
    }
}

/// `notification` の設定（spec: notifications「Notification decision」）。
public struct NotificationSettings: Equatable, Sendable {
    /// デーモンの既定の `notification.commands`（webtabinal `config.DefaultNotifyCommands`）。
    public static let defaultCommands = ["claude", "codex", "cursor-agent", "agent"]

    /// `notification.enabled`（既定は true）。false なら通知も未読も出さない。
    public var enabled = true
    /// `notification.always`（既定は false）。true なら、フォーカス中のアクティブなタブでも通知する。
    public var always = false
    /// `notification.min_duration_ms`（既定は 0）。完了イベントで、これより短いコマンドは通知も未読もしない。
    public var minDurationMs: Int64 = 0
    /// `notification.commands`。空でなければ、コマンド名（先頭の語の basename）がこの中にあるセッションだけ通知する。
    public var commands = NotificationSettings.defaultCommands

    public init(
        enabled: Bool = true,
        always: Bool = false,
        minDurationMs: Int64 = 0,
        commands: [String] = NotificationSettings.defaultCommands
    ) {
        self.enabled = enabled
        self.always = always
        self.minDurationMs = minDurationMs
        self.commands = commands
    }

    /// `commands` が無い・null ならデーモンと同じく既定の一覧にする（空の配列は「すべて」のまま）。
    init(json: [String: Any]) {
        if let value = DisplaySettings.bool(json["enabled"]) { enabled = value }
        if let value = DisplaySettings.bool(json["always"]) { always = value }
        if let value = DisplaySettings.number(json["min_duration_ms"]), value >= 0, value <= Double(Int64.max) {
            minDurationMs = Int64(value)
        }
        if let list = json["commands"] as? [Any] {
            commands = list.compactMap { $0 as? String }
        }
    }
}

/// `state` の設定（エージェント状態の検出。設定画面の「通知」カテゴリで編集する）。
public struct StateSettings: Equatable, Sendable {
    public var enabled = true
    public var debounceMs = 120
    public var quiescenceMs = 1500
    public var bottomLines = 15
    public var notifyOnBlocked = true
    public var notifyOnIdle = false
    public var manifestDir = ""

    public init(
        enabled: Bool = true,
        debounceMs: Int = 120,
        quiescenceMs: Int = 1500,
        bottomLines: Int = 15,
        notifyOnBlocked: Bool = true,
        notifyOnIdle: Bool = false,
        manifestDir: String = ""
    ) {
        self.enabled = enabled
        self.debounceMs = debounceMs
        self.quiescenceMs = quiescenceMs
        self.bottomLines = bottomLines
        self.notifyOnBlocked = notifyOnBlocked
        self.notifyOnIdle = notifyOnIdle
        self.manifestDir = manifestDir
    }

    init(json: [String: Any]) {
        if let value = DisplaySettings.bool(json["enabled"]) { enabled = value }
        if let value = Self.int(json["debounce_ms"]) { debounceMs = value }
        if let value = Self.int(json["quiescence_ms"]) { quiescenceMs = value }
        if let value = Self.int(json["bottom_lines"]) { bottomLines = value }
        if let value = DisplaySettings.bool(json["notify_on_blocked"]) { notifyOnBlocked = value }
        if let value = DisplaySettings.bool(json["notify_on_idle"]) { notifyOnIdle = value }
        if let value = json["manifest_dir"] as? String { manifestDir = value }
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = DisplaySettings.number(value), number >= Double(Int32.min), number <= Double(Int32.max) else { return nil }
        return Int(number)
    }
}

/// 設定画面の「一般」カテゴリの設定（`shell` と `restore.enabled`）。
public struct GeneralSettings: Equatable, Sendable {
    public static let defaultShell = "/bin/zsh"

    /// `shell`（新しいタブで起動するシェル）。
    public var shell = GeneralSettings.defaultShell
    /// `restore.enabled`（エージェントのタブを次回の起動で開き直す。既定は true）。
    public var restoreEnabled = true

    public init(shell: String = GeneralSettings.defaultShell, restoreEnabled: Bool = true) {
        self.shell = shell
        self.restoreEnabled = restoreEnabled
    }

    init(json: [String: Any]) {
        if let value = json["shell"] as? String, !value.isEmpty { shell = value }
        if let restore = json["restore"] as? [String: Any], let value = DisplaySettings.bool(restore["enabled"]) {
            restoreEnabled = value
        }
    }
}

/// タブとサイドバーの設定（config.json と `GET /api/config` の同じ名前のキー）。
public struct TabSettings: Equatable, Sendable {
    public static let defaultSidebarWidth = 240

    /// `sidebar_width`（既定は 240）。
    public var sidebarWidth = TabSettings.defaultSidebarWidth
    /// `confirm_close_running`（既定は true）。
    public var confirmCloseRunning = true
    /// `quit_when_no_tabs`（既定は true）。
    public var quitWhenNoTabs = true
    public var notification = NotificationSettings()
    public var keyBindings = KeyBindings()

    public init(
        sidebarWidth: Int = TabSettings.defaultSidebarWidth,
        confirmCloseRunning: Bool = true,
        quitWhenNoTabs: Bool = true,
        notification: NotificationSettings = NotificationSettings(),
        keyBindings: KeyBindings = KeyBindings()
    ) {
        self.sidebarWidth = sidebarWidth
        self.confirmCloseRunning = confirmCloseRunning
        self.quitWhenNoTabs = quitWhenNoTabs
        self.notification = notification
        self.keyBindings = keyBindings
    }

    /// JSON のオブジェクトから読む。無い・不正な値は既定値にする。未知のキーは無視する。
    init(json: [String: Any]) {
        if let width = DisplaySettings.number(json["sidebar_width"]), width > 0, width <= Double(Int32.max) {
            sidebarWidth = Int(width)
        }
        if let value = DisplaySettings.bool(json["confirm_close_running"]) { confirmCloseRunning = value }
        if let value = DisplaySettings.bool(json["quit_when_no_tabs"]) { quitWhenNoTabs = value }
        if let object = json["notification"] as? [String: Any] { notification = NotificationSettings(json: object) }
        if let object = json["key_bindings"] as? [String: Any] { keyBindings = KeyBindings(json: object) }
    }
}

/// `GET /api/config` / `PATCH /api/config` の応答のうち、クライアントが使うもの。
public struct ClientSettings: Equatable, Sendable {
    public var display: DisplaySettings
    public var tabs: TabSettings
    public var general: GeneralSettings
    public var state: StateSettings

    public init(
        display: DisplaySettings = DisplaySettings(),
        tabs: TabSettings = TabSettings(),
        general: GeneralSettings = GeneralSettings(),
        state: StateSettings = StateSettings()
    ) {
        self.display = display
        self.tabs = tabs
        self.general = general
        self.state = state
    }

    init(json: [String: Any]) {
        display = DisplaySettings(json: json)
        tabs = TabSettings(json: json)
        general = GeneralSettings(json: json)
        state = (json["state"] as? [String: Any]).map(StateSettings.init(json:)) ?? StateSettings()
    }
}

extension ColorSchemeSetting: Encodable {}

/// `PATCH /api/config` で送る変更（変更したキーだけの入れ子の JSON。phase4 design D3）。
///
/// デーモンは入れ子のオブジェクトをフィールド単位でマージし、配列は丸ごと置き換えるので、
/// `notification.commands` は配列全体を送る。`key_bindings` は Web 版と同じくオブジェクト全体を送る。
/// nil の項目は送らない。
public struct ConfigPatch: Equatable, Sendable, Encodable {
    public struct Notification: Equatable, Sendable, Encodable {
        public var enabled: Bool?
        public var always: Bool?
        public var commands: [String]?

        public init(enabled: Bool? = nil, always: Bool? = nil, commands: [String]? = nil) {
            self.enabled = enabled
            self.always = always
            self.commands = commands
        }
    }

    public struct State: Equatable, Sendable, Encodable {
        public var enabled: Bool?
        public var notifyOnBlocked: Bool?
        public var notifyOnIdle: Bool?
        public var debounceMs: Int?
        public var quiescenceMs: Int?
        public var bottomLines: Int?
        public var manifestDir: String?

        public init(
            enabled: Bool? = nil,
            notifyOnBlocked: Bool? = nil,
            notifyOnIdle: Bool? = nil,
            debounceMs: Int? = nil,
            quiescenceMs: Int? = nil,
            bottomLines: Int? = nil,
            manifestDir: String? = nil
        ) {
            self.enabled = enabled
            self.notifyOnBlocked = notifyOnBlocked
            self.notifyOnIdle = notifyOnIdle
            self.debounceMs = debounceMs
            self.quiescenceMs = quiescenceMs
            self.bottomLines = bottomLines
            self.manifestDir = manifestDir
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case notifyOnBlocked = "notify_on_blocked"
            case notifyOnIdle = "notify_on_idle"
            case debounceMs = "debounce_ms"
            case quiescenceMs = "quiescence_ms"
            case bottomLines = "bottom_lines"
            case manifestDir = "manifest_dir"
        }
    }

    public struct Restore: Equatable, Sendable, Encodable {
        public var enabled: Bool?

        public init(enabled: Bool? = nil) {
            self.enabled = enabled
        }
    }

    /// `color_scheme`。
    public var colorScheme: ColorSchemeSetting?
    /// `shell`。
    public var shell: String?
    /// `sidebar_width`。
    public var sidebarWidth: Int?
    /// `shift_enter_newline`。
    public var shiftEnterNewline: Bool?
    /// `key_bindings`（オブジェクト全体）。
    public var keyBindings: KeyBindings?
    public var notification: Notification?
    public var state: State?
    public var restore: Restore?

    /// 手元の値から作ったオブジェクト・配列の全体で置き換える項目（`key_bindings`、`notification.commands`）を含むか。
    /// 手元の値が古いと、ほかのクライアント（ブラウザ版）での変更を上書きしてしまう。
    public var replacesWholeValues: Bool {
        keyBindings != nil || notification?.commands != nil
    }

    public init(
        colorScheme: ColorSchemeSetting? = nil,
        shell: String? = nil,
        sidebarWidth: Int? = nil,
        shiftEnterNewline: Bool? = nil,
        keyBindings: KeyBindings? = nil,
        notification: Notification? = nil,
        state: State? = nil,
        restore: Restore? = nil
    ) {
        self.colorScheme = colorScheme
        self.shell = shell
        self.sidebarWidth = sidebarWidth
        self.shiftEnterNewline = shiftEnterNewline
        self.keyBindings = keyBindings
        self.notification = notification
        self.state = state
        self.restore = restore
    }

    enum CodingKeys: String, CodingKey {
        case colorScheme = "color_scheme"
        case shell
        case sidebarWidth = "sidebar_width"
        case shiftEnterNewline = "shift_enter_newline"
        case keyBindings = "key_bindings"
        case notification, state, restore
    }

    /// この変更が触るキー（楽観的な更新と巻き戻しの単位）。
    public var keys: Set<ConfigKey> {
        var keys: Set<ConfigKey> = []
        if colorScheme != nil { keys.insert(.colorScheme) }
        if shell != nil { keys.insert(.shell) }
        if sidebarWidth != nil { keys.insert(.sidebarWidth) }
        if shiftEnterNewline != nil { keys.insert(.shiftEnterNewline) }
        if keyBindings != nil { keys.insert(.keyBindings) }
        if let notification {
            if notification.enabled != nil { keys.insert(.notificationEnabled) }
            if notification.always != nil { keys.insert(.notificationAlways) }
            if notification.commands != nil { keys.insert(.notificationCommands) }
        }
        if let state {
            if state.enabled != nil { keys.insert(.stateEnabled) }
            if state.notifyOnBlocked != nil { keys.insert(.stateNotifyOnBlocked) }
            if state.notifyOnIdle != nil { keys.insert(.stateNotifyOnIdle) }
            if state.debounceMs != nil { keys.insert(.stateDebounceMs) }
            if state.quiescenceMs != nil { keys.insert(.stateQuiescenceMs) }
            if state.bottomLines != nil { keys.insert(.stateBottomLines) }
            if state.manifestDir != nil { keys.insert(.stateManifestDir) }
        }
        if restore?.enabled != nil { keys.insert(.restoreEnabled) }
        return keys
    }

    /// 変更を設定に当てはめる（保存を待たずに表示を変えるとき）。
    public func apply(to settings: inout ClientSettings) {
        if let colorScheme { settings.display.colorScheme = colorScheme }
        if let shell { settings.general.shell = shell }
        if let sidebarWidth { settings.tabs.sidebarWidth = sidebarWidth }
        if let shiftEnterNewline { settings.display.shiftEnterNewline = shiftEnterNewline }
        if let keyBindings { settings.tabs.keyBindings = keyBindings }
        if let notification {
            if let value = notification.enabled { settings.tabs.notification.enabled = value }
            if let value = notification.always { settings.tabs.notification.always = value }
            if let value = notification.commands { settings.tabs.notification.commands = value }
        }
        if let state {
            if let value = state.enabled { settings.state.enabled = value }
            if let value = state.notifyOnBlocked { settings.state.notifyOnBlocked = value }
            if let value = state.notifyOnIdle { settings.state.notifyOnIdle = value }
            if let value = state.debounceMs { settings.state.debounceMs = value }
            if let value = state.quiescenceMs { settings.state.quiescenceMs = value }
            if let value = state.bottomLines { settings.state.bottomLines = value }
            if let value = state.manifestDir { settings.state.manifestDir = value }
        }
        if let value = restore?.enabled { settings.general.restoreEnabled = value }
    }
}
