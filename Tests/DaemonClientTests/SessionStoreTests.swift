import Foundation
import Testing
@testable import DaemonClient

/// spec: daemon-connection「Session list synchronization」、spec: tab-operations「Active session selection」。
@MainActor
@Suite struct SessionStoreTests {
    private func frame(_ json: String) -> ServerFrame {
        guard let frame = ServerFrame.decode(Data(json.utf8)) else {
            Issue.record("not a frame: \(json)")
            return .unknown(type: "")
        }
        return frame
    }

    private func sessions(_ ids: [String], exited: Set<String> = []) -> ServerFrame {
        .sessions(ids.enumerated().map { index, id in
            SessionInfo(id: id, order: index, cwd: "/Users/me/\(id)", state: exited.contains(id) ? "exited" : "idle")
        })
    }

    // Scenario: Initial sync / Unknown fields
    @Test func framesAreAppliedInOrder() {
        let store = SessionStore()
        var changes = 0
        store.onChange = { changes += 1 }

        store.apply(frame(#"""
        {"t":"sessions","list":[
          {"id":"b","order":0,"cwd":"/b","command":"","state":"idle","exit":null,"integrated":true,"memo":"","agent":"","agent_state":"none","unknown":{"x":1}},
          {"id":"a","order":1,"cwd":"/a","command":"","state":"running","exit":null,"integrated":false,"memo":"m","agent":"","agent_state":"none"}
        ]}
        """#))
        #expect(store.sessions.map(\.id) == ["b", "a"])
        #expect(store.activeSessionID == "b")

        store.apply(frame(#"{"t":"state","sid":"a","cwd":"/a/src","cmd":"vim","state":"running","exit":null,"integrated":false,"run_ms":120}"#))
        #expect(store.sessions[1].cwd == "/a/src")
        #expect(store.sessions[1].command == "vim")
        #expect(store.sessions[1].runMs == 120)
        // ほかのセッションは変わらない。
        #expect(store.sessions[0].cwd == "/b")

        store.apply(frame(#"{"t":"agent_state","sid":"b","agent":"claude","agent_state":"working","agent_state_since":"2026-11-09T00:00:00Z","agent_state_signal":"screen"}"#))
        #expect(store.sessions[0].agent == "claude")
        #expect(store.sessions[0].agentState == "working")
        #expect(store.sessions[0].agentStateSignal == "screen")

        // 一覧は丸ごと置き換える（state で変えた値も、一覧の値で上書きされる）。
        store.apply(sessions(["a", "c"]))
        #expect(store.sessions.map(\.id) == ["a", "c"])
        #expect(store.sessions[0].cwd == "/Users/me/a")

        // 一覧に無いセッションの state は無視する。
        store.apply(frame(#"{"t":"state","sid":"zzz","cwd":"/","cmd":"","state":"idle","exit":null,"integrated":false}"#))
        #expect(store.sessions.map(\.id) == ["a", "c"])
        #expect(changes == 4)
    }

    // Scenario: Active session removed elsewhere
    @Test func activeSessionFallsBackToTheFirstWhenRemoved() {
        let store = SessionStore()
        store.apply(sessions(["a", "b", "c"]))
        store.activate("b")
        #expect(store.activeSession?.id == "b")

        // 残っていれば維持する（並べ替えられても）。
        store.apply(sessions(["c", "b", "a"]))
        #expect(store.activeSessionID == "b")

        // 消えたら先頭。
        store.apply(sessions(["c", "a"]))
        #expect(store.activeSessionID == "c")

        // 空なら無し。
        store.apply(sessions([]))
        #expect(store.activeSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func bootstrapActions() {
        let store = SessionStore()
        #expect(store.bootstrapAction() == nil)

        store.apply(sessions([]))
        #expect(store.bootstrapAction() == .create)

        store.apply(sessions(["a", "b"], exited: ["a"]))
        #expect(store.bootstrapAction() == .restart(id: "a"))

        store.apply(sessions(["a", "b"], exited: ["b"]))
        #expect(store.bootstrapAction() == .useExisting)
    }
}
