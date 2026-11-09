import DaemonClient
import DesktopSupport
import Testing
@testable import Shell

/// spec: notifications「Notification decision」「Notification content」（tasks 3.1 / 3.2）。
///
/// webtabinal `web/tests/notify.test.ts`（16 件）を移したもの。Web 版の関数は `NotificationDecision` の同じ名前の関数にある
/// （`shouldRaiseDesktopNotification` → `shouldRaise`）。
@Suite struct NotifyPortTests {
    typealias D = NotificationDecision

    // wait notify is shown for a background tab
    @Test func waitNotifyIsShownForABackgroundTab() {
        #expect(D.shouldRaise(enabled: true, always: false, active: false, focused: true))
    }

    // wait notify is suppressed for the focused active tab
    @Test func waitNotifyIsSuppressedForTheFocusedActiveTab() {
        #expect(!D.shouldRaise(enabled: true, always: false, active: true, focused: true))
    }

    // wait notify ignores min duration
    @Test func waitNotifyIgnoresMinDuration() {
        #expect(D.shouldRaise(enabled: true, always: false, active: false, focused: false))
    }

    // completion still respects min duration when provided
    @Test func completionStillRespectsMinDurationWhenProvided() {
        #expect(!D.shouldRaise(enabled: true, always: false, active: false, focused: false, minDurationMs: 5000, runMs: 1000))
    }

    // always allows a focused active wait notification
    @Test func alwaysAllowsAFocusedActiveWaitNotification() {
        #expect(D.shouldRaise(enabled: true, always: true, active: true, focused: true))
    }

    // blocked wait events stay eligible without a duration threshold
    @Test func blockedWaitEventsStayEligibleWithoutADurationThreshold() {
        #expect(D.shouldRaise(enabled: true, always: false, active: false, focused: false))
    }

    // disabled notifications skip wait alerts
    @Test func disabledNotificationsSkipWaitAlerts() {
        #expect(!D.shouldRaise(enabled: false, always: true, active: false, focused: false))
    }

    // agent wait content falls back to command then WebTabinal（Tabghostty では `Tabghostty`）
    @Test func agentWaitContentFallsBackToCommandThenTabghostty() {
        #expect(D.agentWaitContent(title: "", body: "needs approval", command: "codex") == NotificationContent(title: "codex", body: "needs approval"))
        #expect(D.agentWaitContent(title: "", body: "needs approval", command: nil) == NotificationContent(title: "Tabghostty", body: "needs approval"))
        #expect(D.agentWaitContent(title: "  ", body: "  ", command: "codex") == nil)
        #expect(D.agentWaitContent(title: "Codex", body: "Waiting for input", command: nil) == NotificationContent(title: "Codex", body: "Waiting for input"))
    }

    private static let agents = ["claude", "codex", "cursor-agent", "agent"]

    // whitelist matches the command name
    @Test func whitelistMatchesTheCommandName() {
        #expect(D.commandAllowsNotification("claude", Self.agents))
        #expect(!D.commandAllowsNotification("ls", Self.agents))
    }

    // whitelist ignores arguments and the executable path
    @Test func whitelistIgnoresArgumentsAndTheExecutablePath() {
        #expect(D.commandAllowsNotification("claude --resume", Self.agents))
        #expect(D.commandAllowsNotification("/usr/local/bin/claude --resume", Self.agents))
        #expect(D.commandAllowsNotification("  make   build  ", ["make"]))
        #expect(!D.commandAllowsNotification("make build", Self.agents))
    }

    // an empty whitelist disables the restriction
    @Test func anEmptyWhitelistDisablesTheRestriction() {
        #expect(D.commandAllowsNotification("ls", []))
        #expect(D.commandAllowsNotification("", []))
        #expect(D.commandAllowsNotification(nil, []))
    }

    // an unknown command is not allowed while a whitelist is set
    @Test func anUnknownCommandIsNotAllowedWhileAWhitelistIsSet() {
        #expect(!D.commandAllowsNotification("", Self.agents))
        #expect(!D.commandAllowsNotification("   ", Self.agents))
        #expect(!D.commandAllowsNotification(nil, Self.agents))
    }

    // whitelist entries are trimmed and matched on the whole name
    @Test func whitelistEntriesAreTrimmedAndMatchedOnTheWholeName() {
        #expect(D.commandAllowsNotification("claude", [" claude "]))
        #expect(!D.commandAllowsNotification("claude", ["clau"]))
        #expect(!D.commandAllowsNotification("claude", ["claudex"]))
    }

    // whitelist matching ignores case
    @Test func whitelistMatchingIgnoresCase() {
        #expect(D.commandAllowsNotification("task", ["Task"]))
        #expect(D.commandAllowsNotification("Task", ["task"]))
        #expect(D.commandAllowsNotification("/usr/bin/TASK --run", ["task"]))
        #expect(!D.commandAllowsNotification("taskrunner", ["Task"]))
    }

    // a muted tab withholds banners
    @Test func aMutedTabWithholdsBanners() {
        #expect(!D.sessionAllowsNotification(SessionInfo(id: "s", notificationsMuted: true)))
    }

    // an unmuted or unknown tab allows banners
    @Test func anUnmutedOrUnknownTabAllowsBanners() {
        #expect(D.sessionAllowsNotification(SessionInfo(id: "s", notificationsMuted: false)))
        #expect(D.sessionAllowsNotification(nil))
    }
}

/// spec のシナリオを `NotificationDecision.evaluate` で確かめる。
@Suite struct NotificationDecisionTests {
    typealias D = NotificationDecision

    private func finished(_ command: String = "make", runMs: Int64? = 10_000, exit: Int? = 0, muted: Bool = false) -> SessionInfo {
        SessionInfo(id: "s", cwd: "/Users/me/app", command: command, state: "idle", exit: exit, notificationsMuted: muted, runMs: runMs)
    }

    private func evaluateCompletion(
        _ session: SessionInfo,
        active: Bool = false,
        focused: Bool = true,
        config: NotificationSettings = NotificationSettings(commands: [])
    ) -> D.Result {
        D.evaluate(event: .commandFinished(session), session: session, isActive: active, windowFocused: focused, config: config)
    }

    private func evaluateWait(
        _ session: SessionInfo,
        title: String = "Claude Code",
        body: String = "Turn complete",
        active: Bool = false,
        focused: Bool = true,
        config: NotificationSettings = NotificationSettings(commands: [])
    ) -> D.Result {
        D.evaluate(event: .agentWaiting(sid: session.id, title: title, body: body), session: session, isActive: active, windowFocused: focused, config: config)
    }

    // Scenario: Focused active tab
    @Test func focusedActiveTabShowsNothing() {
        #expect(evaluateCompletion(finished(), active: true, focused: true) == .none)
    }

    // Scenario: Always
    @Test func alwaysShowsForTheFocusedActiveTabWithoutMarkingIt() {
        let result = evaluateCompletion(finished(), active: true, focused: true, config: NotificationSettings(always: true, commands: []))
        #expect(result.content != nil)
        #expect(!result.markUnread)
    }

    // アクティブなタブでも、ウィンドウにフォーカスが無ければ通知する（未読にはしない）。
    @Test func activeTabWithoutFocusIsNotified() {
        let result = evaluateCompletion(finished(), active: true, focused: false)
        #expect(result.content != nil)
        #expect(!result.markUnread)
    }

    // Scenario: Short command
    @Test func shortCommandIsNeitherNotifiedNorMarked() {
        let config = NotificationSettings(minDurationMs: 5000, commands: [])
        #expect(evaluateCompletion(finished(runMs: 2000), config: config) == .none)
        #expect(evaluateCompletion(finished(runMs: nil), config: config) == .none)
        #expect(evaluateCompletion(finished(runMs: 5000), config: config).markUnread)
    }

    // Scenario: Wait ignores min duration
    @Test func waitIgnoresMinDuration() {
        let result = evaluateWait(finished(), config: NotificationSettings(minDurationMs: 5000, commands: []))
        #expect(result == D.Result(markUnread: true, content: NotificationContent(title: "Claude Code", body: "Turn complete")))
    }

    // Scenario: Command list
    @Test func commandListMatchesTheBasenameIgnoringCase() {
        let config = NotificationSettings(commands: ["claude", "codex"])
        let result = evaluateCompletion(finished("/opt/homebrew/bin/Claude --resume"), config: config)
        #expect(result.content != nil)
    }

    // Scenario: Not in command list
    @Test func notInCommandListIsMarkedButNotNotified() {
        let config = NotificationSettings(commands: ["claude"])
        #expect(evaluateCompletion(finished("npm test"), config: config) == D.Result(markUnread: true, content: nil))
        #expect(evaluateWait(finished("npm test"), config: config) == D.Result(markUnread: true, content: nil))
    }

    // Scenario: Muted
    @Test func mutedTabIsMarkedButNotNotified() {
        #expect(evaluateWait(finished(muted: true)) == D.Result(markUnread: true, content: nil))
    }

    @Test func disabledShowsAndMarksNothing() {
        let config = NotificationSettings(enabled: false, commands: [])
        #expect(evaluateCompletion(finished()) != .none)
        #expect(evaluateCompletion(finished(), config: config) == .none)
        #expect(evaluateWait(finished(), config: config) == .none)
    }

    // 空の title と body の待ちイベントは、未読にもしない。
    @Test func blankWaitIsIgnored() {
        #expect(evaluateWait(finished(), title: " ", body: "") == .none)
    }

    // MARK: - 内容

    // Scenario: Failed build
    @Test func failedBuildContent() {
        let session = SessionInfo(id: "s", cwd: "/Users/me/app", command: "make", state: "idle", exit: 2, runMs: 12_400)
        #expect(D.completionContent(session) == NotificationContent(title: "✗ make (exit 2)", body: "app ・ 12s"))
    }

    @Test func successfulAndUnknownExitContent() {
        #expect(D.completionContent(finished("npm test", runMs: 1500, exit: 0)) == NotificationContent(title: "✓ npm test", body: "app ・ 2s"))
        #expect(D.completionContent(finished("ls", runMs: nil, exit: nil)) == NotificationContent(title: "✓ ls", body: "app ・ 0s"))
        let home = SessionInfo(id: "s", cwd: "/Users/me", command: "sleep 3", state: "idle", exit: 130, runMs: 3499)
        #expect(D.completionContent(home) == NotificationContent(title: "✗ sleep 3 (exit 130)", body: "~ ・ 3s"))
    }

    // Scenario: Hook notification — title が空なら、セッションのコマンド、`Tabghostty` の順。
    @Test func hookNotificationContent() {
        #expect(evaluateWait(finished()).content == NotificationContent(title: "Claude Code", body: "Turn complete"))
        #expect(evaluateWait(finished("codex"), title: "", body: "needs approval").content == NotificationContent(title: "codex", body: "needs approval"))
        #expect(evaluateWait(finished(""), title: "", body: "needs approval").content == NotificationContent(title: "Tabghostty", body: "needs approval"))
    }
}

/// `NotificationCoordinator`（イベント → 判定 → 未読 → 通知）の結合テスト（tasks 3.2）。
/// webtabinal `app.test.ts` の通知に関するケースを移したもの。
@MainActor
@Suite(.serialized) struct NotificationCoordinatorTests {
    private func complete(_ harness: ShellHarness, _ sid: String, cmd: String = "claude", exit: String = "0", runMs: Int = 12_400) {
        harness.store.apply(harness.frame(#"{"t":"state","sid":"\#(sid)","cwd":"/Users/me/app","cmd":"\#(cmd)","state":"running","exit":null,"integrated":true,"run_ms":0}"#))
        harness.store.apply(harness.frame(#"{"t":"state","sid":"\#(sid)","cwd":"/Users/me/app","cmd":"\#(cmd)","state":"idle","exit":\#(exit),"integrated":true,"run_ms":\#(runMs)}"#))
    }

    private func agent(_ id: String, command: String = "claude", muted: Bool = false) -> SessionInfo {
        SessionInfo(id: id, cwd: "/Users/me/\(id)", command: command, state: "idle", integrated: true, notificationsMuted: muted)
    }

    @Test func backgroundCompletionAndWaitAreNotifiedWithTheirContent() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([agent("a"), agent("b"), agent("c")])
        complete(harness, "b", cmd: "claude", exit: "2")
        harness.store.apply(.notify(sid: "c", title: "Claude Code", body: "Turn complete"))
        #expect(await waitUntil { harness.notifier.shown.count == 2 })
        #expect(harness.notifier.shown == [
            .init(sid: "b", title: "✗ claude (exit 2)", body: "app ・ 12s"),
            .init(sid: "c", title: "Claude Code", body: "Turn complete"),
        ])
        #expect(harness.shell.unread.unreadIDs == ["b", "c"])
    }

    // フォーカス中のアクティブなタブは、`always` が無効なら通知しない。
    @Test func focusedActiveTabIsSuppressedUnlessAlways() async throws {
        var client = ClientSettings(tabs: TabSettings(notification: NotificationSettings(commands: [])))
        client.display.colorScheme = .dark
        let harness = try ShellHarness(client: client)
        harness.shell.notifications.isWindowFocused = { true }
        await harness.liveSessions([agent("a"), agent("b")])
        complete(harness, "a")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.notifier.shown.isEmpty)

        // 「操作中も通知する」を有効にする（ブラウザ版で変えて読み直した）。
        harness.configAPI.server.tabs.notification.always = true
        await harness.config.reload()
        complete(harness, "a")
        #expect(await waitUntil { harness.notifier.shown.count == 1 })
        #expect(harness.shell.unread.unreadIDs.isEmpty)
    }

    // notification.commands gates banners for both completion and agent events
    @Test func commandsGateBannersForBothCompletionAndAgentEvents() async throws {
        let harness = try ShellHarness(settings: TabSettings(notification: NotificationSettings(commands: ["claude"])))
        await harness.liveSessions([agent("a"), agent("b", command: "npm test"), agent("c", command: "/usr/local/bin/Claude --resume")])
        complete(harness, "b", cmd: "npm test")
        harness.store.apply(.notify(sid: "b", title: "Done", body: ""))
        harness.store.apply(.notify(sid: "c", title: "Claude Code", body: "Turn complete"))
        #expect(await waitUntil { harness.notifier.shown.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.notifier.shown.map(\.sid) == ["c"])
        // 一覧から外れたタブも未読は付く。
        #expect(harness.shell.unread.unreadIDs == ["b", "c"])
    }

    // a muted tab raises no banner but stays unread while other tabs notify
    @Test func mutedTabRaisesNoBannerButStaysUnread() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([agent("a"), agent("b", muted: true), agent("c")])
        harness.store.apply(.notify(sid: "b", title: "Claude Code", body: "Ready"))
        harness.store.apply(.notify(sid: "c", title: "Claude Code", body: "Ready"))
        #expect(await waitUntil { harness.notifier.shown.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.notifier.shown.map(\.sid) == ["c"])
        #expect(harness.shell.unread.unreadIDs == ["b", "c"])
        #expect(harness.dock.badgeLabel == "2")
    }

    // Scenario: Denied — 通知は出ないが、未読と Dock バッジは付く。
    @Test func deniedPermissionStillMarksUnreadAndBadges() async throws {
        let harness = try ShellHarness()
        harness.notifier.permissionState = .denied
        await harness.liveSessions([agent("a"), agent("b")])
        complete(harness, "b")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.notifier.shown.isEmpty)
        #expect(harness.shell.unread.unreadIDs == ["b"])
        #expect(harness.dock.badgeLabel == "1")
    }

    // Scenario: Changed in browser — ブラウザ版で通知を無効にして、前面に戻した（読み直した）ら通知しない。
    @Test func disablingNotificationsElsewhereTakesEffectAfterReload() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([agent("a"), agent("b")])
        harness.configAPI.server.tabs.notification.enabled = false
        await harness.config.reload()
        complete(harness, "b")
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.notifier.shown.isEmpty)
        #expect(harness.shell.unread.unreadIDs.isEmpty)
    }
}

/// spec: notifications「Delivery and activation」（tasks 3.3）。通知のクリックでタブを選ぶ。
///
/// `AppDelegate` と同じつなぎ方（`onSessionsReady` で `markReady`、クリックで `receive`、渡されたら `select`）で確かめる。
@MainActor
@Suite(.serialized) struct NotificationActivationTests {
    private func wire(_ harness: ShellHarness) -> NotificationActivationCoordinator {
        let activation = NotificationActivationCoordinator()
        harness.shell.onSessionsReady = { [weak shell = harness.shell] in
            activation.markReady { shell?.select($0) }
        }
        return activation
    }

    private func click(_ activation: NotificationActivationCoordinator, _ harness: ShellHarness, _ sid: String) {
        activation.receive(sessionID: sid) { [weak shell = harness.shell] in shell?.select($0) }
    }

    // Scenario: Click selects the tab
    @Test func clickSelectsTheTab() async throws {
        let harness = try ShellHarness()
        let activation = wire(harness)
        await harness.liveSessions([session("a"), session("b")])
        harness.store.apply(.notify(sid: "b", title: "Claude Code", body: "Turn complete"))
        #expect(harness.shell.unread.contains("b"))
        click(activation, harness, "b")
        #expect(harness.store.activeSessionID == "b")
        #expect(!harness.shell.unread.contains("b"))
    }

    // セッション一覧を受け取る前のクリックは、受け取ってから選ぶ（起動直後に通知から開いたとき）。
    @Test func clickBeforeTheSessionListIsAppliedOnceItArrives() async throws {
        let harness = try ShellHarness()
        let activation = wire(harness)
        click(activation, harness, "b")
        #expect(activation.pendingSessionID == "b")
        await harness.liveSessions([session("a"), session("b")])
        #expect(harness.store.activeSessionID == "b")
        #expect(activation.pendingSessionID == nil)
    }

    // Scenario: Session gone — 閉じたタブの通知をクリックしても、アクティブなタブは変わらない。
    @Test func clickForAClosedSessionKeepsTheActiveTab() async throws {
        let harness = try ShellHarness()
        let activation = wire(harness)
        await harness.liveSessions([session("a"), session("b")])
        click(activation, harness, "gone")
        #expect(harness.store.activeSessionID == "a")
    }

    // 「選べる状態になった」は、最初の一覧で 1 回だけ知らせる。
    @Test func sessionsReadyIsReportedOnce() async throws {
        let harness = try ShellHarness()
        var reports = 0
        harness.shell.onSessionsReady = { reports += 1 }
        await harness.deliver(.sessions([session("a")]))
        await harness.deliver(.sessions([session("a"), session("b")]))
        #expect(reports == 1)
    }
}
