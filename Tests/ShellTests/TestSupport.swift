import AppKit
import DesktopSupport
import Foundation
import os
@testable import DaemonClient
@testable import Shell
import TerminalCore
import TerminalUI

/// 条件が満たされるまで待つ（満たされなければ false）。
@MainActor
func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// 送ったフレームを記録する。
final class RecordingSink: TerminalFrameSink, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [TerminalOutgoingFrame]())

    var frames: [TerminalOutgoingFrame] { state.withLock { $0 } }

    var inputBytes: [UInt8] {
        frames.flatMap { frame -> [UInt8] in
            if case .input(_, let bytes) = frame { return bytes }
            return []
        }
    }

    var resizes: [String] {
        frames.compactMap { frame in
            if case .resize(let sid, let cols, let rows) = frame { return "\(sid):\(cols)x\(rows)" }
            return nil
        }
    }

    func removeAll() { state.withLock { $0.removeAll() } }

    @discardableResult
    func enqueue(_ frame: TerminalOutgoingFrame) -> Bool {
        state.withLock { $0.append(frame) }
        return true
    }
}

/// REST の代わり。
final class FakeSessionAPI: SessionAPI, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "request failed" }
    }

    private let state = OSAllocatedUnfairLock(initialState: [String]())
    var calls: [String] { state.withLock { $0 } }
    var failMute = false

    private func record(_ call: String) { state.withLock { $0.append(call) } }

    func createSession(cwd: String?) async throws -> SessionInfo { record("create"); return SessionInfo(id: "created") }
    func restartSession(id: String) async throws -> SessionInfo { record("restart:\(id)"); return SessionInfo(id: "restarted") }
    func duplicateSession(id: String) async throws -> SessionInfo { record("duplicate:\(id)"); return SessionInfo(id: "duplicated") }
    func deleteSession(id: String) async throws { record("delete:\(id)") }
    func updateSessionMemo(id: String, memo: String) async throws -> SessionInfo { record("memo:\(id):\(memo)"); return SessionInfo(id: id) }
    func setSessionNotificationsMuted(id: String, muted: Bool) async throws -> SessionInfo {
        record("mute:\(id):\(muted)")
        if failMute { throw Failure() }
        return SessionInfo(id: id)
    }
    func reorderSessions(ids: [String]) async throws { record("order:\(ids.joined(separator: ","))") }
}

/// 設定の REST の代わり。PATCH は `failPatches` が true なら失敗し、そうでなければ当てはめた設定を返す。
final class FakeConfigAPI: ConfigAPI, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private struct State {
        var server = ClientSettings()
        var patches: [ConfigPatch] = []
        var failure: String?
        var fetches = 0
        var held = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var reject: (@Sendable (ConfigPatch) -> String?)?
    }

    /// PATCH の内容でデーモンの検証を真似る（エラーの文言を返したら失敗させる）。
    var reject: (@Sendable (ConfigPatch) -> String?)? {
        get { state.withLockUnchecked { $0.reject } }
        set { state.withLockUnchecked { $0.reject = newValue } }
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// true の間、PATCH の応答を止める（保存中の状態を見るため）。
    func holdPatches(_ held: Bool) {
        let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Void, Never>] in
            state.held = held
            guard !held else { return [] }
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    var server: ClientSettings {
        get { state.withLockUnchecked { $0.server } }
        set { state.withLockUnchecked { $0.server = newValue } }
    }

    /// 次からの PATCH を、このメッセージで失敗させる（nil なら成功させる）。
    var failure: String? {
        get { state.withLockUnchecked { $0.failure } }
        set { state.withLockUnchecked { $0.failure = newValue } }
    }

    var patches: [ConfigPatch] { state.withLockUnchecked { $0.patches } }
    var fetches: Int { state.withLockUnchecked { $0.fetches } }

    func fetchSettings() async throws -> ClientSettings {
        state.withLockUnchecked { state in
            state.fetches += 1
            return state.server
        }
    }

    func patchConfig(_ patch: ConfigPatch) async throws -> ClientSettings {
        state.withLockUnchecked { $0.patches.append(patch) }
        if state.withLockUnchecked({ $0.held }) {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLockUnchecked { state -> Bool in
                    guard state.held else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return try state.withLockUnchecked { state in
            if let failure = state.failure ?? state.reject?(patch) { throw Failure(message: failure) }
            patch.apply(to: &state.server)
            return state.server
        }
    }
}

/// 通知の代わり。出した通知を記録する。
final class FakeNotificationService: NativeNotificationServicing, @unchecked Sendable {
    struct Shown: Equatable {
        var sid: String
        var title: String
        var body: String
    }

    private struct State {
        var permission = DesktopNotificationPermission.granted
        var afterRequest = DesktopNotificationPermission.granted
        var shown: [Shown] = []
        var requests = 0
        var queries = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var permissionState: DesktopNotificationPermission {
        get { state.withLock { $0.permission } }
        set { state.withLock { $0.permission = newValue } }
    }

    var permissionAfterRequest: DesktopNotificationPermission {
        get { state.withLock { $0.afterRequest } }
        set { state.withLock { $0.afterRequest = newValue } }
    }

    var shown: [Shown] { state.withLock { $0.shown } }
    var requests: Int { state.withLock { $0.requests } }
    var queries: Int { state.withLock { $0.queries } }

    func permission() async -> DesktopNotificationPermission {
        state.withLock { state in
            state.queries += 1
            return state.permission
        }
    }

    func requestPermission() async throws -> DesktopNotificationPermission {
        state.withLock { state in
            state.requests += 1
            state.permission = state.afterRequest
            return state.permission
        }
    }

    func show(sessionID: String, title: String, body: String) async throws {
        try state.withLock { state in
            guard state.permission == .granted else {
                throw NativeNotificationServiceError.permissionNotGranted(state.permission)
            }
            state.shown.append(Shown(sid: sessionID, title: title, body: body))
        }
    }
}

/// 画像のアップロードの代わり。`results` の順に応答する（パスなら成功、nil なら失敗）。`gate` が閉じている間は待つ。
final class FakeImageUploader: ImageUploadAPI, @unchecked Sendable {
    struct Failure: Error {}

    private struct State {
        var results: [String?] = []
        var uploads: [(sid: String, data: Data, mime: String)] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        var held = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(results: [String?] = []) {
        state.withLockUnchecked { $0.results = results }
    }

    var uploads: [(sid: String, data: Data, mime: String)] { state.withLockUnchecked { $0.uploads } }

    /// true の間、アップロードの応答を止める。
    var held: Bool {
        get { state.withLockUnchecked { $0.held } }
        set {
            let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Void, Never>] in
                state.held = newValue
                guard !newValue else { return [] }
                defer { state.waiters.removeAll() }
                return state.waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func uploadImage(sessionID: String, data: Data, mimeType: String) async throws -> SavedImage {
        // 始めた時点で記録する（応答を止めている間にも、送ったことが分かる）。
        state.withLockUnchecked { $0.uploads.append((sessionID, data, mimeType)) }
        if state.withLockUnchecked({ $0.held }) {
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLockUnchecked { state -> Bool in
                    guard state.held else { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        let result = state.withLockUnchecked { state -> String?? in
            state.results.isEmpty ? .some(nil) : state.results.removeFirst()
        }
        guard let path = result ?? nil else { throw Failure() }
        return SavedImage(path: path, name: "", mime: mimeType, bytes: data.count)
    }
}

/// Dock のアイコンの代わり。
@MainActor
final class FakeDockTile: DockBadging {
    var badgeLabel: String?
}

/// `TabShellController` をオフスクリーンのウィンドウに載せたもの。端末は `RecordingSink` に送る。
@MainActor
struct ShellHarness {
    let shell: TabShellController
    let coordinator: SessionCoordinator
    let terminalView: TerminalView
    let window: NSWindow
    let sink: RecordingSink
    let api: FakeSessionAPI
    let dock: FakeDockTile

    var store: SessionStore { coordinator.store }

    let configAPI: FakeConfigAPI
    let notifier: FakeNotificationService
    let uploader: FakeImageUploader

    var config: ConfigStore { shell.config }

    init(
        settings: TabSettings = TabSettings(),
        client: ClientSettings? = nil,
        chordTimeout: Double? = nil,
        uploader: FakeImageUploader = FakeImageUploader()
    ) throws {
        let sink = RecordingSink()
        let api = FakeSessionAPI()
        var initial = client ?? ClientSettings(tabs: settings)
        if client == nil {
            initial.display.colorScheme = .dark
        }
        let terminalView = TerminalView(
            fontFamily: initial.display.fontFamily,
            fontSize: CGFloat(initial.display.fontSize),
            palette: initial.display.colorScheme == .light ? .light : .dark
        )
        // 接続は始めない（フレームは `deliver` で直接渡す）。
        let connection = WSConnection(port: 9, token: "token")
        let appearance = AppearanceController(scheme: initial.display.colorScheme, application: nil)
        let coordinator = SessionCoordinator(connection: connection, api: api) { [weak appearance] sid, _ in
            try TerminalController(
                sid: sid, cols: 80, rows: 24, maxScrollback: 1000,
                colors: appearance?.theme.palette.terminalColors, sink: sink
            )
        }
        let configAPI = FakeConfigAPI()
        configAPI.server = initial
        let config = ConfigStore(settings: initial, api: configAPI)
        let notifier = FakeNotificationService()
        let dock = FakeDockTile()
        let shell = TabShellController(
            coordinator: coordinator,
            terminalView: terminalView,
            config: config,
            editor: ConfigEditor(store: config, api: configAPI),
            appearance: appearance,
            notificationService: notifier,
            imageUploader: uploader,
            dockTile: dock
        )
        if let chordTimeout {
            shell.chord.timeout = chordTimeout
        }
        terminalView.onGridChange = { [weak coordinator] grid in coordinator?.viewGrid = grid }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = shell.splitViewController
        window.setContentSize(NSSize(width: 1000, height: 600))
        shell.splitViewController.view.layoutSubtreeIfNeeded()
        shell.attach(to: window)

        self.shell = shell
        self.coordinator = coordinator
        self.terminalView = terminalView
        self.window = window
        self.sink = sink
        self.api = api
        self.dock = dock
        self.configAPI = configAPI
        self.notifier = notifier
        self.uploader = uploader
    }

    /// デーモンからフレームが届いたことにする。
    func deliver(_ frame: ServerFrame) async {
        await coordinator.handle(.frame(frame))
    }

    /// 一覧を届け、各セッションを replay し終えて live にする。
    func liveSessions(_ sessions: [SessionInfo]) async {
        await deliver(.sessions(sessions))
        for session in sessions {
            await deliver(.replay(sid: session.id, data: Array("I am \(session.id)".utf8), done: true))
        }
    }

    func frame(_ json: String) -> ServerFrame {
        ServerFrame.decode(Data(json.utf8)) ?? .unknown(type: "")
    }

    func key(_ characters: String, keyCode: UInt16, ignoring: String? = nil, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode
        )!
    }
}

func session(_ id: String, state: String = "idle", cwd: String? = nil, muted: Bool = false, runMs: Int64? = nil) -> SessionInfo {
    SessionInfo(id: id, cwd: cwd ?? "/Users/me/\(id)", state: state, integrated: true, notificationsMuted: muted, runMs: runMs)
}
