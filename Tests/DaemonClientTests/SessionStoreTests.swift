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
    // 読めないセッションが 1 つあっても、ほかのセッションの一覧は反映する（一覧の更新全体は捨てない）。
    @Test func aMalformedSessionIsSkippedNotTheWholeList() throws {
        let json = #"{"t":"sessions","list":[{"id":"a","state":"idle"},{"state":"idle"},{"id":"c","order":"oops"},{"id":"d","future_field":1}]}"#
        let frame = try #require(ServerFrame.decode(Data(json.utf8)))
        guard case .sessions(let list) = frame else {
            Issue.record("expected a sessions frame: \(frame)")
            return
        }
        #expect(list.map(\.id) == ["a", "d"])
    }

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

    // 作った（複製した・再起動した）セッションは、一覧に入った時点でアクティブにする。REST の応答と `sessions` は別の接続で届くので、
    // 作る前の一覧が応答の後に届くことがある。そのときも先頭のタブに戻さず、それまでのアクティブセッションを保つ。
    @Test func aRequestedSessionBecomesActiveWhenListedEvenAfterAStaleList() {
        let store = SessionStore()
        store.apply(sessions(["a", "b"]))
        store.activate("b")

        store.activate("new")
        store.apply(sessions(["a", "b"]))
        #expect(store.activeSessionID == "b")

        store.apply(sessions(["a", "b", "new"]))
        #expect(store.activeSessionID == "new")
    }

    // 一覧に入る前にほかのタブを選んだら、そちらを優先する（後から一覧に入っても切り替えない）。
    @Test func choosingAnotherTabCancelsAPendingActivation() {
        let store = SessionStore()
        store.apply(sessions(["a", "b"]))
        store.activate("new")
        store.activate("a")
        store.apply(sessions(["a", "b", "new"]))
        #expect(store.activeSessionID == "a")
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
    // MARK: - 通知の対象になるイベント（phase3 tasks 4.1、design D3）

    private func state(_ sid: String, _ value: String, exit: String = "null", runMs: Int = 0) -> ServerFrame {
        frame(#"{"t":"state","sid":"\#(sid)","cwd":"/a","cmd":"make","state":"\#(value)","exit":\#(exit),"integrated":true,"run_ms":\#(runMs)}"#)
    }

    @Test func runningToIdleEmitsACompletionEventAfterApplyingTheState() {
        let store = SessionStore()
        store.apply(sessions(["a", "b"]))
        var events: [SessionEvent] = []
        var cwdAtEvent: String?
        store.onEvent = { event in
            events.append(event)
            cwdAtEvent = store.sessions.first { $0.id == event.sid }?.cwd
        }

        store.apply(state("a", "running"))
        #expect(events.isEmpty)
        store.apply(state("a", "idle", exit: "0", runMs: 4200))
        #expect(events.count == 1)
        guard case .commandFinished(let session) = events.first else {
            Issue.record("expected a completion event")
            return
        }
        // 反映した後のセッションを渡す。
        #expect(session.id == "a")
        #expect(session.runMs == 4200)
        #expect(session.exit == 0)
        #expect(cwdAtEvent == "/a")

        // running 以外から idle、running から running / exited は完了イベントにしない。
        store.apply(state("a", "idle"))
        store.apply(state("b", "starting"))
        store.apply(state("b", "idle"))
        store.apply(state("b", "running"))
        store.apply(state("b", "running"))
        store.apply(state("b", "exited", exit: "1"))
        #expect(events.count == 1)
    }

    @Test func notifyEmitsAWaitEventOnlyWhenTitleOrBodyIsNotBlank() {
        let store = SessionStore()
        store.apply(sessions(["a"]))
        var events: [SessionEvent] = []
        var changes = 0
        store.onEvent = { events.append($0) }
        store.onChange = { changes += 1 }

        store.apply(.notify(sid: "a", title: "  ", body: "\n"))
        store.apply(.notify(sid: "a", title: "", body: ""))
        #expect(events.isEmpty)

        store.apply(.notify(sid: "a", title: "Claude Code", body: ""))
        store.apply(.notify(sid: "a", title: "", body: "Ready"))
        #expect(events == [
            .agentWaiting(sid: "a", title: "Claude Code", body: ""),
            .agentWaiting(sid: "a", title: "", body: "Ready"),
        ])
        // 一覧に無いセッションの notify は無視する。
        store.apply(.notify(sid: "zzz", title: "x", body: "y"))
        #expect(events.count == 2)
        // notify では一覧は変わらない。
        #expect(changes == 0)
    }

    @Test func notificationsMutedCanBeChangedLocallyUntilTheNextList() {
        let store = SessionStore()
        store.apply(sessions(["a", "b"]))
        var changes = 0
        store.onChange = { changes += 1 }
        store.setNotificationsMuted("a", true)
        #expect(store.sessions[0].notificationsMuted)
        #expect(store.sessions[1].notificationsMuted == false)
        // 同じ値・一覧に無いセッションでは何もしない。
        store.setNotificationsMuted("a", true)
        store.setNotificationsMuted("zzz", true)
        #expect(changes == 1)
        // デーモンの一覧で置き換わる。
        store.apply(frame(#"{"t":"sessions","list":[{"id":"a","notifications_muted":false},{"id":"b","notifications_muted":true}]}"#))
        #expect(store.sessions.map(\.notificationsMuted) == [false, true])
    }
}
