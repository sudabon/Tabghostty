import Foundation
import os
import Testing
@testable import DaemonClient

/// `ConfigAPI` の代わり。`GET` は `next` を返し、`PATCH` は `patchHandler` に任せる（保留して後から応答できる）。
final class FakeConfigAPI: ConfigAPI, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private struct State {
        var next = ClientSettings()
        var fetchFails = false
        var fetches = 0
        var patches: [ConfigPatch] = []
        var deferred: [CheckedContinuation<ClientSettings, Error>] = []
        var holdPatches = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var next: ClientSettings {
        get { state.withLock { $0.next } }
        set { state.withLock { $0.next = newValue } }
    }

    var fetchFails: Bool {
        get { state.withLock { $0.fetchFails } }
        set { state.withLock { $0.fetchFails = newValue } }
    }

    /// true なら `PATCH` の応答を保留する（`resolve` / `reject` で返す）。
    var holdPatches: Bool {
        get { state.withLock { $0.holdPatches } }
        set { state.withLock { $0.holdPatches = newValue } }
    }

    var fetches: Int { state.withLock { $0.fetches } }
    var patches: [ConfigPatch] { state.withLock { $0.patches } }
    var pendingCount: Int { state.withLock { $0.deferred.count } }

    func fetchSettings() async throws -> ClientSettings {
        try state.withLock { state in
            state.fetches += 1
            if state.fetchFails { throw Failure(message: "fetch failed") }
            return state.next
        }
    }

    func patchConfig(_ patch: ConfigPatch) async throws -> ClientSettings {
        let hold = state.withLock { state -> Bool in
            state.patches.append(patch)
            return state.holdPatches
        }
        if !hold {
            return state.withLock { state in
                patch.apply(to: &state.next)
                return state.next
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.deferred.append(continuation) }
        }
    }

    /// 保留している `index` 番目の PATCH に、`settings` で応答する。
    func resolve(_ index: Int, with settings: ClientSettings) {
        state.withLock { $0.deferred[index] }.resume(returning: settings)
    }

    func reject(_ index: Int, _ message: String) {
        state.withLock { $0.deferred[index] }.resume(throwing: Failure(message: message))
    }
}

@MainActor
func settled(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// spec: settings-window「Configuration changes take effect without restart」（tasks 1.1）。
@MainActor
@Suite struct ConfigStoreTests {
    @Test func changedKeysAreDetected() {
        var next = ClientSettings()
        #expect(ConfigKey.changes(from: ClientSettings(), to: next).isEmpty)
        next.display.fontSize = 16
        next.tabs.notification.enabled = false
        next.state.debounceMs = 300
        #expect(ConfigKey.changes(from: ClientSettings(), to: next) == [.fontSize, .notificationEnabled, .stateDebounceMs])
    }

    // 変わったキーにだけ通知が届く。
    @Test func reloadNotifiesOnlyTheObserversOfChangedKeys() async {
        let api = FakeConfigAPI()
        let store = ConfigStore(settings: ClientSettings(), api: api)
        var fontCalls: [Set<ConfigKey>] = []
        var schemeCalls = 0
        var notificationCalls: [Set<ConfigKey>] = []
        store.observe([.fontFamily, .fontSize]) { settings, changed in
            #expect(settings.display.fontSize == 16)
            fontCalls.append(changed)
        }
        store.observe([.colorScheme]) { _, _ in schemeCalls += 1 }
        store.observe([.notificationEnabled, .notificationAlways]) { _, changed in notificationCalls.append(changed) }

        var next = ClientSettings()
        next.display.fontSize = 16
        next.tabs.notification.enabled = false
        api.next = next
        #expect(await store.reload())
        #expect(store.settings == next)
        #expect(store.committed == next)
        #expect(fontCalls == [[.fontSize]])
        #expect(schemeCalls == 0)
        #expect(notificationCalls == [[.notificationEnabled]])

        // 変わっていなければ、だれにも知らせない。
        #expect(await store.reload())
        #expect(fontCalls.count == 1)
        #expect(notificationCalls.count == 1)
        #expect(api.fetches == 2)
    }

    @Test func failedReloadKeepsTheCurrentSettings() async {
        let api = FakeConfigAPI()
        var initial = ClientSettings()
        initial.display.fontSize = 18
        let store = ConfigStore(settings: initial, api: api)
        var calls = 0
        store.observe(Set(ConfigKey.allCases)) { _, _ in calls += 1 }
        api.fetchFails = true
        #expect(await store.reload() == false)
        #expect(store.settings == initial)
        #expect(calls == 0)
    }

    @Test func removedObserverIsNotCalled() async {
        let api = FakeConfigAPI()
        let store = ConfigStore(settings: ClientSettings(), api: api)
        var calls = 0
        let observation = store.observe([.fontSize]) { _, _ in calls += 1 }
        store.removeObservation(observation)
        api.next.display.fontSize = 20
        await store.reload()
        #expect(calls == 0)
    }

    // 保存中のキーは、読み直しで上書きしない（保存が終わったら応答の値になる）。
    @Test func reloadDoesNotOverwriteAKeyBeingSaved() async throws {
        let api = FakeConfigAPI()
        let store = ConfigStore(settings: ClientSettings(), api: api)
        let editor = ConfigEditor(store: store, api: api)
        api.holdPatches = true
        let edit = Task { try await editor.apply(ConfigPatch(colorScheme: .dark)) }
        #expect(await settled { api.pendingCount == 1 })
        #expect(store.settings.display.colorScheme == .dark)

        var server = ClientSettings()
        server.display.fontSize = 13
        api.next = server
        await store.reload()
        #expect(store.settings.display.colorScheme == .dark)
        #expect(store.settings.display.fontSize == 13)

        server.display.colorScheme = .dark
        api.resolve(0, with: server)
        try await edit.value
        #expect(store.settings == server)
        #expect(store.committed == server)
    }
}
