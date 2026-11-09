import Foundation
import os

/// 設定のキー（変わったことを知らせる単位と、楽観的な更新・巻き戻しの単位。phase4 design D4）。
public enum ConfigKey: String, CaseIterable, Sendable {
    case colorScheme
    case fontFamily
    case fontSize
    case scrollbackLines
    case shiftEnterNewline
    case copyOnSelect
    case sidebarWidth
    case confirmCloseRunning
    case quitWhenNoTabs
    case keyBindings
    case notificationEnabled
    case notificationAlways
    case notificationMinDurationMs
    case notificationCommands
    case stateEnabled
    case stateNotifyOnBlocked
    case stateNotifyOnIdle
    case stateDebounceMs
    case stateQuiescenceMs
    case stateBottomLines
    case stateManifestDir
    case shell
    case restoreEnabled

    /// 2 つの設定で、このキーの値が同じか。
    public func isEqual(_ a: ClientSettings, _ b: ClientSettings) -> Bool {
        accessor.isEqual(a, b)
    }

    /// このキーの値だけを `source` から `target` に写す。
    public func copy(from source: ClientSettings, to target: inout ClientSettings) {
        accessor.copy(source, &target)
    }

    /// 2 つの設定で値が違うキー。
    public static func changes(from old: ClientSettings, to new: ClientSettings) -> Set<ConfigKey> {
        Set(allCases.filter { !$0.isEqual(old, new) })
    }

    private struct Accessor {
        let isEqual: (ClientSettings, ClientSettings) -> Bool
        let copy: (ClientSettings, inout ClientSettings) -> Void

        init<Value: Equatable>(_ path: WritableKeyPath<ClientSettings, Value>) {
            isEqual = { $0[keyPath: path] == $1[keyPath: path] }
            copy = { source, target in target[keyPath: path] = source[keyPath: path] }
        }
    }

    private var accessor: Accessor {
        switch self {
        case .colorScheme: Accessor(\.display.colorScheme)
        case .fontFamily: Accessor(\.display.fontFamily)
        case .fontSize: Accessor(\.display.fontSize)
        case .scrollbackLines: Accessor(\.display.scrollbackLines)
        case .shiftEnterNewline: Accessor(\.display.shiftEnterNewline)
        case .copyOnSelect: Accessor(\.display.copyOnSelect)
        case .sidebarWidth: Accessor(\.tabs.sidebarWidth)
        case .confirmCloseRunning: Accessor(\.tabs.confirmCloseRunning)
        case .quitWhenNoTabs: Accessor(\.tabs.quitWhenNoTabs)
        case .keyBindings: Accessor(\.tabs.keyBindings)
        case .notificationEnabled: Accessor(\.tabs.notification.enabled)
        case .notificationAlways: Accessor(\.tabs.notification.always)
        case .notificationMinDurationMs: Accessor(\.tabs.notification.minDurationMs)
        case .notificationCommands: Accessor(\.tabs.notification.commands)
        case .stateEnabled: Accessor(\.state.enabled)
        case .stateNotifyOnBlocked: Accessor(\.state.notifyOnBlocked)
        case .stateNotifyOnIdle: Accessor(\.state.notifyOnIdle)
        case .stateDebounceMs: Accessor(\.state.debounceMs)
        case .stateQuiescenceMs: Accessor(\.state.quiescenceMs)
        case .stateBottomLines: Accessor(\.state.bottomLines)
        case .stateManifestDir: Accessor(\.state.manifestDir)
        case .shell: Accessor(\.general.shell)
        case .restoreEnabled: Accessor(\.general.restoreEnabled)
        }
    }
}

/// 設定の読み書きに使う REST（テストで差し替える）。
public protocol ConfigAPI: Sendable {
    func fetchSettings() async throws -> ClientSettings
    @discardableResult
    func patchConfig(_ patch: ConfigPatch) async throws -> ClientSettings
}

extension RESTClient: ConfigAPI {}

/// 設定の置き場所（phase4 design D4）。各コンポーネントはここを参照し、変わったキーだけの知らせを受け取る。
///
/// - `settings` は表示に使う値（保存中の変更を含む）。`committed` はデーモンが保存済みと返した値（巻き戻し先）。
/// - デーモンは config の変化を知らせないので、アプリが前面に来たとき・設定画面を開いたとき・再接続したときに
///   `reload()` で `GET /api/config` を読み直す（ブラウザ版で変えた設定を拾う）。
/// - 変更は `ConfigEditor` から行う（楽観的に表示を変え、失敗したら戻す）。
@MainActor
public final class ConfigStore {
    public typealias Handler = @MainActor (_ settings: ClientSettings, _ changed: Set<ConfigKey>) -> Void

    /// 観察をやめるときに使う。
    public struct Observation: Hashable, Sendable {
        let id: Int
    }

    /// 表示に使う値（保存中の変更を含む）。
    public private(set) var settings: ClientSettings
    /// デーモンが保存済みと返した値。
    public private(set) var committed: ClientSettings

    private let api: any ConfigAPI
    private var observers: [(id: Int, keys: Set<ConfigKey>, handler: Handler)] = []
    private var nextObserverID = 0
    /// 保存中の変更の数（キーごと）。読み直しでは、保存中のキーを上書きしない。
    private var pendingEdits: [ConfigKey: Int] = [:]
    /// 変更の保存が終わった順番（キーごとの最後の値）。読み直しの最中に保存が終わったキーは、読み直しの結果で上書きしない。
    private var editSequence = 0
    private var lastFinishedEdit: [ConfigKey: Int] = [:]
    private var reloadGeneration = 0
    private static let log = Logger(subsystem: "com.tabghostty.app", category: "config")
    /// 最後の読み直しが失敗した理由。読めたら nil。失敗している間は、手元の値が古いかもしれない。
    public private(set) var reloadError: String?

    public init(settings: ClientSettings, api: any ConfigAPI) {
        self.settings = settings
        committed = settings
        self.api = api
    }

    /// `keys` のどれかが変わったら `handler` を呼ぶ（変わったキーのうち `keys` に含まれるものを渡す）。
    @discardableResult
    public func observe(_ keys: Set<ConfigKey>, _ handler: @escaping Handler) -> Observation {
        nextObserverID += 1
        observers.append((nextObserverID, keys, handler))
        return Observation(id: nextObserverID)
    }

    public func removeObservation(_ observation: Observation) {
        observers.removeAll { $0.id == observation.id }
    }

    /// `GET /api/config` で読み直し、変わったキーを知らせる。保存中のキーは上書きしない。読めたら true。
    @discardableResult
    public func reload() async -> Bool {
        reloadGeneration += 1
        let generation = reloadGeneration
        let startedAt = editSequence
        let fetched: ClientSettings
        do {
            fetched = try await api.fetchSettings()
        } catch {
            Self.log.error("Failed to reload the configuration: \(error.localizedDescription, privacy: .public)")
            // 新しい読み直しを始めていれば、そちらの結果に任せる。
            if generation == reloadGeneration {
                reloadError = ConfigEditor.message(for: error)
            }
            return false
        }
        // 新しい読み直しを始めていれば、そちらの結果に任せる。
        guard generation == reloadGeneration else { return true }
        reloadError = nil
        var nextCommitted = committed
        var nextSettings = settings
        for key in ConfigKey.allCases {
            if pendingEdits[key, default: 0] > 0 || lastFinishedEdit[key, default: 0] > startedAt { continue }
            key.copy(from: fetched, to: &nextCommitted)
            key.copy(from: fetched, to: &nextSettings)
        }
        committed = nextCommitted
        setSettings(nextSettings)
        return true
    }

    // MARK: - ConfigEditor から

    func beginEdit(_ keys: Set<ConfigKey>, optimistic: ClientSettings) {
        for key in keys {
            pendingEdits[key, default: 0] += 1
        }
        setSettings(optimistic)
    }

    func endEdit(_ keys: Set<ConfigKey>, committed: ClientSettings, settings: ClientSettings) {
        editSequence += 1
        for key in keys {
            pendingEdits[key, default: 1] -= 1
            if pendingEdits[key] == 0 { pendingEdits[key] = nil }
            lastFinishedEdit[key] = editSequence
        }
        self.committed = committed
        setSettings(settings)
    }

    private func setSettings(_ next: ClientSettings) {
        let changed = ConfigKey.changes(from: settings, to: next)
        settings = next
        guard !changed.isEmpty else { return }
        for observer in observers {
            let relevant = changed.intersection(observer.keys)
            if !relevant.isEmpty {
                observer.handler(next, relevant)
            }
        }
    }
}

/// 設定を保存しなかった理由。
public enum ConfigEditError: Error, Equatable, LocalizedError {
    /// 最新の設定を読み込めていないので、全体で置き換える変更を送らなかった。
    case settingsMayBeStale

    public var errorDescription: String? {
        switch self {
        case .settingsMayBeStale:
            return "The latest settings could not be loaded from the daemon, so this change was not saved (it could overwrite changes made elsewhere). Try again."
        }
    }
}

/// 設定の変更（phase4 design D3）。楽観的に表示を変え、変更したキーだけを入れた `PATCH /api/config` を送り、
/// 失敗したら保存済みの値に戻してエラーを投げる。
///
/// 同じキーを素早く何度も変えたときは、webtabinal `App.tsx`（L485-511。配色の競合への対策）と同じく、
/// 古い応答で新しい表示を巻き戻さない。
/// - 成功: 一番新しい変更なら応答の値にする。古い変更なら、それより新しい変更がすべて失敗していれば保存済みの値にする。
/// - 失敗: 一番新しい変更なら保存済みの値に戻してエラーを投げる。新しい変更に追い越されていれば何もしない（投げない）。
@MainActor
public final class ConfigEditor {
    public let store: ConfigStore
    private let api: any ConfigAPI
    private var requestCounter = 0
    /// キーごとの一番新しい変更。
    private var latestRequest: [ConfigKey: Int] = [:]
    /// キーごとの、成功した中で一番新しい変更。
    private var lastSuccessfulRequest: [ConfigKey: Int] = [:]
    /// キーごとの保存中の変更。
    private var inFlight: [ConfigKey: Set<Int>] = [:]

    public init(store: ConfigStore, api: any ConfigAPI) {
        self.store = store
        self.api = api
    }

    /// 変更を保存する。失敗したら、表示を戻してから投げる。
    ///
    /// 最後の読み直しが失敗していて、手元の値から作った全体で置き換える変更（`key_bindings`、`notification.commands`）なら、
    /// ブラウザ版での変更を上書きしないよう送らずに `ConfigEditError.settingsMayBeStale` を投げ、読み直しを始める。
    public func apply(_ patch: ConfigPatch) async throws {
        let keys = patch.keys
        guard !keys.isEmpty else { return }
        if patch.replacesWholeValues, store.reloadError != nil {
            Task { await store.reload() }
            throw ConfigEditError.settingsMayBeStale
        }
        requestCounter += 1
        let request = requestCounter
        for key in keys {
            latestRequest[key] = request
            inFlight[key, default: []].insert(request)
        }
        var optimistic = store.settings
        patch.apply(to: &optimistic)
        store.beginEdit(keys, optimistic: optimistic)

        let result: Result<ClientSettings, Error>
        do {
            result = .success(try await api.patchConfig(patch))
        } catch {
            result = .failure(error)
        }
        for key in keys {
            inFlight[key]?.remove(request)
        }

        var committed = store.committed
        var settings = store.settings
        switch result {
        case .success(let response):
            for key in keys {
                if request > lastSuccessfulRequest[key, default: 0] {
                    lastSuccessfulRequest[key] = request
                    key.copy(from: response, to: &committed)
                }
                if latestRequest[key] == request {
                    key.copy(from: response, to: &settings)
                } else if !(inFlight[key]?.contains { $0 > request } ?? false) {
                    // 新しい変更はすべて失敗している。保存済みの値に合わせる。
                    key.copy(from: committed, to: &settings)
                }
            }
            store.endEdit(keys, committed: committed, settings: settings)
        case .failure(let error):
            let current = keys.filter { latestRequest[$0] == request }
            for key in current {
                key.copy(from: committed, to: &settings)
            }
            store.endEdit(keys, committed: committed, settings: settings)
            if !current.isEmpty {
                throw error
            }
        }
    }

    /// エラーを利用者に見せる文言（デーモンが返した本文があれば、それを使う。Web 版と同じ）。
    public nonisolated static func message(for error: Error) -> String {
        if let rest = error as? RESTError, rest.status != nil, !rest.detail.isEmpty {
            return rest.detail
        }
        return error.localizedDescription
    }
}
