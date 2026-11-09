import Foundation
import os
import Testing
@testable import DaemonClient

/// spec: settings-window「Settings window layout」（即時保存と巻き戻し。tasks 1.2）、
/// spec: color-scheme「Scheme applies everywhere」（素早く変えたときの競合。tasks 2.2）。
@MainActor
@Suite struct ConfigEditorTests {
    private let token = "f00dbabe-not-a-real-token-1234567890"

    private nonisolated static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // PATCH のボディは、変更したキーだけを入れた入れ子の JSON。commands は配列全体を送る。
    @Test func patchBodiesNestOnlyTheChangedKeys() async throws {
        let server = try MockHTTPServer { request in
            guard request.method == "PATCH", request.path == "/api/config" else { return .text(404, "Not Found", "") }
            // デーモンは変更後の設定全体を返す。
            var response = Self.json(request.body) ?? [:]
            response["port"] = 8642
            let data = try! JSONSerialization.data(withJSONObject: response)
            return .json(200, String(decoding: data, as: UTF8.self))
        }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)
        let store = ConfigStore(settings: ClientSettings(), api: client)
        let editor = ConfigEditor(store: store, api: client)

        try await editor.apply(ConfigPatch(notification: .init(enabled: false)))
        try await editor.apply(ConfigPatch(notification: .init(commands: ["claude", "codex", "make"])))
        try await editor.apply(ConfigPatch(state: .init(quiescenceMs: 2000)))
        try await editor.apply(ConfigPatch(restore: .init(enabled: false)))
        try await editor.apply(ConfigPatch(colorScheme: .light))

        let bodies = server.requests.map { Self.json($0.body) ?? [:] }
        #expect(bodies.count == 5)
        #expect(bodies[0] as? [String: [String: Bool]] == ["notification": ["enabled": false]])
        #expect(bodies[1] as? [String: [String: [String]]] == ["notification": ["commands": ["claude", "codex", "make"]]])
        #expect(bodies[2] as? [String: [String: Int]] == ["state": ["quiescence_ms": 2000]])
        #expect(bodies[3] as? [String: [String: Bool]] == ["restore": ["enabled": false]])
        #expect(bodies[4] as? [String: String] == ["color_scheme": "light"])
        for request in server.requests {
            #expect(request.headers["content-type"] == "application/json")
        }
        #expect(store.settings.tabs.notification.enabled == false)
        #expect(store.settings.tabs.notification.commands == ["claude", "codex", "make"])
        #expect(store.settings.state.quiescenceMs == 2000)
        #expect(store.settings.general.restoreEnabled == false)
        #expect(store.settings.display.colorScheme == .light)
    }

    // 失敗したら元に戻し、デーモンが返した本文をエラーとして投げる。
    @Test func failedPatchRollsBackAndReportsTheDaemonMessage() async throws {
        let server = try MockHTTPServer { _ in
            .text(400, "Bad Request", "shell: stat /no/such/shell: no such file or directory\n")
        }
        try await server.start()
        defer { server.stop() }
        let client = RESTClient(port: server.port, token: token)
        let store = ConfigStore(settings: ClientSettings(), api: client)
        let editor = ConfigEditor(store: store, api: client)
        var observed: [String] = []
        store.observe([.shell]) { settings, _ in observed.append(settings.general.shell) }

        do {
            try await editor.apply(ConfigPatch(shell: "/no/such/shell"))
            Issue.record("the patch must fail")
        } catch {
            #expect(ConfigEditor.message(for: error) == "shell: stat /no/such/shell: no such file or directory")
            #expect(!ConfigEditor.message(for: error).contains(token))
        }
        // 保存を待たずに表示を変え、失敗したら戻す。
        #expect(observed == ["/no/such/shell", "/bin/zsh"])
        #expect(store.settings.general.shell == "/bin/zsh")
        #expect(store.committed.general.shell == "/bin/zsh")
    }

    // 保存の途中でも、表示はすでに新しい値。
    @Test func optimisticValueIsVisibleWhileSaving() async throws {
        let api = FakeConfigAPI()
        api.holdPatches = true
        let store = ConfigStore(settings: ClientSettings(), api: api)
        let editor = ConfigEditor(store: store, api: api)
        let task = Task { try await editor.apply(ConfigPatch(notification: .init(enabled: false))) }
        #expect(await settled { api.pendingCount == 1 })
        #expect(store.settings.tabs.notification.enabled == false)
        #expect(store.committed.tabs.notification.enabled == true)
        var saved = ClientSettings()
        saved.tabs.notification.enabled = false
        api.resolve(0, with: saved)
        try await task.value
        #expect(store.committed.tabs.notification.enabled == false)
    }

    // MARK: - app.test.ts「color-scheme race」

    private func scheme(_ value: ColorSchemeSetting) -> ClientSettings {
        var settings = ClientSettings()
        settings.display.colorScheme = value
        return settings
    }

    // latest failed color scheme change rolls back to the server-confirmed scheme
    @Test func latestFailedColorSchemeChangeRollsBackToTheServerConfirmedScheme() async throws {
        let api = FakeConfigAPI()
        api.holdPatches = true
        let store = ConfigStore(settings: scheme(.system), api: api)
        let editor = ConfigEditor(store: store, api: api)
        var errors: [String] = []

        let dark = Task { do { try await editor.apply(ConfigPatch(colorScheme: .dark)) } catch { errors.append("dark") } }
        #expect(await settled { api.pendingCount == 1 })
        #expect(store.settings.display.colorScheme == .dark)
        let light = Task { do { try await editor.apply(ConfigPatch(colorScheme: .light)) } catch { errors.append("light") } }
        #expect(await settled { api.pendingCount == 2 })
        #expect(store.settings.display.colorScheme == .light)

        api.reject(1, "light failed")
        await light.value
        api.reject(0, "dark failed")
        await dark.value

        #expect(store.settings.display.colorScheme == .system)
        // 古い変更の失敗は、新しい変更に追い越されているので知らせない。
        #expect(errors == ["light"])
    }

    // stale successful color scheme syncs UI after a newer failure
    @Test func staleSuccessfulColorSchemeSyncsUIAfterANewerFailure() async throws {
        let api = FakeConfigAPI()
        api.holdPatches = true
        let store = ConfigStore(settings: scheme(.system), api: api)
        let editor = ConfigEditor(store: store, api: api)

        let dark = Task { try? await editor.apply(ConfigPatch(colorScheme: .dark)) }
        #expect(await settled { api.pendingCount == 1 })
        let light = Task { try? await editor.apply(ConfigPatch(colorScheme: .light)) }
        #expect(await settled { api.pendingCount == 2 })

        api.reject(1, "light failed")
        await light.value
        #expect(store.settings.display.colorScheme == .system)

        api.resolve(0, with: scheme(.dark))
        await dark.value
        #expect(store.settings.display.colorScheme == .dark)
        #expect(store.committed.display.colorScheme == .dark)
    }

    // 古い変更が成功しても、まだ保存中の新しい変更の表示を巻き戻さない。
    @Test func staleSuccessDoesNotOverrideANewerPendingChange() async throws {
        let api = FakeConfigAPI()
        api.holdPatches = true
        let store = ConfigStore(settings: scheme(.system), api: api)
        let editor = ConfigEditor(store: store, api: api)

        let dark = Task { try? await editor.apply(ConfigPatch(colorScheme: .dark)) }
        #expect(await settled { api.pendingCount == 1 })
        let light = Task { try? await editor.apply(ConfigPatch(colorScheme: .light)) }
        #expect(await settled { api.pendingCount == 2 })

        api.resolve(0, with: scheme(.dark))
        await dark.value
        #expect(store.settings.display.colorScheme == .light)
        api.resolve(1, with: scheme(.light))
        await light.value
        #expect(store.settings.display.colorScheme == .light)
        #expect(store.committed.display.colorScheme == .light)
    }
}
