import DaemonClient
import Testing
@testable import Shell

/// spec: tab-sidebar「Unread dots and Dock badge」（phase3 tasks 4.2）。
///
/// 未読にするかの判定は `NotificationDecision`（`NotificationDecisionTests`）。ここでは `UnreadTracker` と Dock のバッジ、
/// webtabinal `app.test.ts` の未読とミュートに関するケースを `TabShellController` の結合テストで確かめる。
@MainActor
@Suite(.serialized) struct UnreadTests {
    // MARK: - UnreadTracker と Dock のバッジ

    @Test func trackerMarksClearsAndRetains() {
        let tracker = UnreadTracker()
        var changes = 0
        tracker.onChange = { changes += 1 }
        tracker.markUnread("a")
        tracker.markUnread("a")
        tracker.markUnread("b")
        #expect(tracker.unreadIDs == ["a", "b"])
        #expect(changes == 2)
        tracker.markRead("a")
        tracker.markRead("a")
        #expect(tracker.unreadIDs == ["b"])
        tracker.retain(only: ["a", "c"])
        #expect(tracker.unreadIDs.isEmpty)
        #expect(changes == 4)
    }

    @Test func dockBadgeShowsTheCountAndClearsAtZero() {
        #expect(DockBadge.label(for: 0) == nil)
        #expect(DockBadge.label(for: 3) == "3")
        let tile = FakeDockTile()
        let badge = DockBadge(tile: tile)
        badge.update(count: 2)
        #expect(tile.badgeLabel == "2")
        badge.update(count: 0)
        #expect(tile.badgeLabel == nil)
    }

    // MARK: - app.test.ts（結合テスト）

    private func complete(_ harness: ShellHarness, _ sid: String, runMs: Int = 5) {
        harness.store.apply(harness.frame(#"{"t":"state","sid":"\#(sid)","cwd":"/tmp","cmd":"claude","state":"running","exit":null,"integrated":true,"run_ms":0}"#))
        harness.store.apply(harness.frame(#"{"t":"state","sid":"\#(sid)","cwd":"/tmp","cmd":"claude","state":"idle","exit":0,"integrated":true,"run_ms":\#(runMs)}"#))
    }

    // Scenario: Background completion / Selecting clears
    @Test func backgroundCompletionIsUnreadUntilSelected() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b"), session("c")])
        #expect(harness.store.activeSessionID == "a")

        complete(harness, "b")
        #expect(harness.shell.unread.unreadIDs == ["b"])
        #expect(harness.dock.badgeLabel == "1")
        #expect(harness.shell.sidebar.rows.first { $0.id == "b" }?.isUnread == true)

        // アクティブなタブのコマンドが終わっても未読にしない。
        complete(harness, "a")
        #expect(harness.shell.unread.unreadIDs == ["b"])

        harness.store.apply(.notify(sid: "c", title: "Approval needed", body: "Codex is waiting"))
        #expect(harness.dock.badgeLabel == "2")

        harness.shell.select("b")
        #expect(harness.store.activeSessionID == "b")
        #expect(harness.shell.unread.unreadIDs == ["c"])
        #expect(harness.dock.badgeLabel == "1")
        #expect(harness.shell.sidebar.rows.first { $0.id == "b" }?.isUnread == false)
    }

    // Scenario: Muted tab — a muted tab raises no banner but stays unread while other tabs notify
    @Test func mutedTabsStillBecomeUnread() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b", muted: true)])
        harness.store.apply(.notify(sid: "b", title: "Claude Code", body: "Ready"))
        #expect(harness.shell.unread.contains("b"))
        complete(harness, "b")
        #expect(harness.dock.badgeLabel == "1")
    }

    // Scenario: Closed tab — 閉じたタブはバッジの数から外す（Web 版の不具合を直す）。
    @Test func closedTabsStopCounting() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b"), session("c")])
        complete(harness, "b")
        complete(harness, "c")
        #expect(harness.dock.badgeLabel == "2")
        await harness.deliver(.sessions([session("a"), session("c")]))
        #expect(harness.shell.unread.unreadIDs == ["c"])
        #expect(harness.dock.badgeLabel == "1")
    }

    // agent_state frames update pills without replacing shell state or dropping unread
    @Test func agentStateFramesKeepUnread() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b")])
        complete(harness, "b")
        harness.store.apply(harness.frame(#"{"t":"agent_state","sid":"b","agent":"codex","agent_state":"blocked","agent_state_since":"2026-01-01T00:00:00Z","agent_state_signal":"screen"}"#))
        #expect(harness.shell.unread.contains("b"))
        #expect(harness.shell.sidebar.rows[1].pill?.kind == .blocked)
        #expect(harness.store.sessions[1].state == "idle")
    }

    // notification.enabled が false なら未読にしない。min_duration_ms より短い完了も未読にしない。
    @Test func settingsGateUnread() async throws {
        let disabled = try ShellHarness(settings: TabSettings(notification: NotificationSettings(enabled: false)))
        await disabled.liveSessions([session("a"), session("b")])
        complete(disabled, "b")
        disabled.store.apply(.notify(sid: "b", title: "x", body: ""))
        #expect(disabled.shell.unread.unreadIDs.isEmpty)
        #expect(disabled.dock.badgeLabel == nil)

        let threshold = try ShellHarness(settings: TabSettings(notification: NotificationSettings(minDurationMs: 1000)))
        await threshold.liveSessions([session("a"), session("b")])
        complete(threshold, "b", runMs: 500)
        #expect(threshold.shell.unread.unreadIDs.isEmpty)
        complete(threshold, "b", runMs: 1500)
        #expect(threshold.shell.unread.unreadIDs == ["b"])
    }
}
