import AppKit
import DaemonClient
import Testing
@testable import Shell

/// spec: tab-sidebar（tasks 3.1 / 3.3 / 3.4）。
@MainActor
@Suite struct TabPresentationTests {
    // MARK: - 3.1 chrome トークンと cwdBasename

    @Test func chromeTokensMatchTheWebVersion() {
        #expect(ChromePalette.dark.sidebar == ChromeColor(hex: 0x252526))
        #expect(ChromePalette.light.sidebar == ChromeColor(hex: 0xf3f3f3))
        #expect(ChromePalette.dark.active == ChromeColor(hex: 0x2a2d2e))
        #expect(ChromePalette.light.active == ChromeColor(hex: 0xe4e6f1))
        #expect(ChromePalette.dark.accent == ChromeColor(hex: 0x89d185))
        #expect(ChromePalette.light.danger == ChromeColor(hex: 0xcd3131))
        #expect(ChromePalette.dark.overlay == ChromeColor(hex: 0, alpha: 0.55))
        #expect(ChromePalette.resolve(colorScheme: "light", systemIsDark: true) == .light)
        #expect(ChromePalette.resolve(colorScheme: "dark", systemIsDark: false) == .dark)
        #expect(ChromePalette.resolve(colorScheme: "system", systemIsDark: true) == .dark)
        #expect(ChromePalette.resolve(colorScheme: "system", systemIsDark: false) == .light)
    }

    // webtabinal `util.ts` の `cwdBasename` と同じ結果になること。
    @Test(arguments: [
        ("", "~"),
        ("/", "/"),
        ("//", "/"),
        ("/Users/me", "~"),
        ("/Users/me/", "~"),
        ("/home/me", "~"),
        ("/Users", "Users"),
        ("/Users/me/app", "app"),
        ("/Users/me/app/", "app"),
        ("/Users/me/work/tabghostty", "tabghostty"),
        ("/tmp", "tmp"),
        ("/private/var/tmp", "tmp"),
        ("relative/dir", "dir"),
    ])
    func cwdBasenameMatchesTheWebVersion(cwd: String, expected: String) {
        #expect(cwdBasename(cwd) == expected)
    }

    @Test func elapsedIsFormattedAsMinutesAndSeconds() {
        #expect(formatElapsed(nil) == "0:00")
        #expect(formatElapsed(0) == "0:00")
        #expect(formatElapsed(-5) == "0:00")
        #expect(formatElapsed(999) == "0:00")
        #expect(formatElapsed(75_000) == "1:15")
        #expect(formatElapsed(605_400) == "10:05")
    }

    // MARK: - 3.3 行の表示内容

    // Scenario: Running command
    @Test func runningCommand() {
        let model = TabRowModel(
            session: SessionInfo(id: "s", cwd: "/Users/me/app", command: "npm test", state: "running", integrated: true, runMs: 75_000),
            isActive: true,
            isUnread: false
        )
        #expect(model.title == "app")
        #expect(model.command == "npm test")
        #expect(model.commandToolTip == "npm test")
        #expect(model.stateText == "● running 1:15")
        #expect(model.stateStyle == .running)
        #expect(model.isCommandDimmed == false)
        #expect(model.showsNoIntegration == false)
        #expect(model.isActive)
        #expect(model.isExited == false)
    }

    @Test func exitedWithAndWithoutACode() {
        let failed = TabRowModel(session: SessionInfo(id: "s", cwd: "/tmp", state: "exited", exit: 2), isActive: false, isUnread: false)
        #expect(failed.stateText == "■ exit 2")
        #expect(failed.stateStyle == .error)
        #expect(failed.isExited)
        #expect(failed.isCommandDimmed)

        let unknown = TabRowModel(session: SessionInfo(id: "s", state: "exited", exit: nil), isActive: false, isUnread: false)
        #expect(unknown.stateText == "■ exit ?")
        #expect(unknown.stateStyle == .muted)

        let clean = TabRowModel(session: SessionInfo(id: "s", state: "exited", exit: 0), isActive: false, isUnread: false)
        #expect(clean.stateText == "■ exit 0")
        #expect(clean.stateStyle == .muted)
    }

    // Scenario: Failed command — idle で、最後の終了コードが 0 以外なら danger の色。
    @Test func failedCommandWhileIdleUsesTheDangerColor() {
        let model = TabRowModel(session: SessionInfo(id: "s", command: "make", state: "idle", exit: 2), isActive: false, isUnread: false)
        #expect(model.stateText == "○ idle")
        #expect(model.stateStyle == .error)
    }

    @Test func startingIdleEmptyCommandAndNoIntegration() {
        let starting = TabRowModel(session: SessionInfo(id: "s", cwd: "", state: "starting"), isActive: false, isUnread: true)
        #expect(starting.title == "~")
        #expect(starting.stateText == "○ starting")
        #expect(starting.command == "zsh")
        #expect(starting.commandToolTip == nil)
        #expect(starting.isCommandDimmed)
        #expect(starting.showsNoIntegration)
        #expect(starting.isUnread)

        let idle = TabRowModel(session: SessionInfo(id: "s", state: "idle", integrated: true, memo: "  レビュー対応  "), isActive: false, isUnread: false)
        #expect(idle.stateText == "○ idle")
        #expect(idle.stateStyle == .muted)
        #expect(idle.memo == "レビュー対応")
        // 未知の状態も idle と同じに表示する。
        let unknown = TabRowModel(session: SessionInfo(id: "s", state: "zombie"), isActive: false, isUnread: false)
        #expect(unknown.stateText == "○ idle")
    }

    // MARK: - 3.4 状態 pill（webtabinal `agent-state-pill.test.ts` の移植）

    // agent pill omits none and labels idle working blocked
    @Test func agentPillOmitsNoneAndLabelsIdleWorkingBlocked() {
        #expect(AgentPillModel(agent: "", state: "none") == nil)
        #expect(AgentPillModel(agent: "codex", state: "") == nil)

        let working = AgentPillModel(agent: "codex", state: "working")
        #expect(working?.accessibilityLabel == "Codex working")
        #expect(working?.kind == .working)
        #expect(working?.showsSpinner == true)

        // Scenario: Claude Code waiting for approval
        let blocked = AgentPillModel(agent: "claude", state: "blocked")
        #expect(blocked?.accessibilityLabel == "Claude Code blocked")
        #expect(blocked?.kind == .blocked)
        #expect(blocked?.showsSpinner == false)
        #expect(blocked?.text == "blocked")

        let idle = AgentPillModel(agent: "codex", state: "idle")
        #expect(idle?.accessibilityLabel == "Codex idle")
        #expect(idle?.kind == .idle)

        #expect(agentStateLabel(agent: "claude", state: "blocked") == "Claude Code blocked")
        #expect(agentStateLabel(agent: "generic", state: "idle") == "Generic TUI idle")
        #expect(agentStateLabel(agent: "cursor-agent", state: "working") == "cursor-agent working")
        #expect(agentStateLabel(agent: "", state: "working") == "Agent working")
        #expect(agentStateLabel(agent: "claude", state: "none") == "")
    }

    @Test func pillViewFollowsReduceMotionAndExposesTheLabel() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let pill = AgentStatePillView(palette: .dark)
        var reduceMotion = false
        pill.reduceMotion = { reduceMotion }
        window.contentView?.addSubview(pill)

        pill.model = AgentPillModel(agent: "claude", state: "working")
        #expect(!pill.isHidden)
        #expect(pill.text == "working")
        #expect(pill.accessibilityLabel() == "Claude Code working")
        #expect(pill.showsSpinner)
        #expect(pill.isSpinnerAnimating)

        // 「視差効果を減らす」が有効なら止める（印は出したまま）。
        reduceMotion = true
        pill.reduceMotion = { reduceMotion }
        #expect(pill.showsSpinner)
        #expect(!pill.isSpinnerAnimating)

        pill.model = AgentPillModel(agent: "claude", state: "blocked")
        #expect(!pill.showsSpinner)
        #expect(pill.accessibilityLabel() == "Claude Code blocked")

        // Scenario: No agent
        pill.model = nil
        #expect(pill.isHidden)
    }

    // Pill changes SHALL NOT reorder tabs.
    @Test func sidebarKeepsTheDaemonOrderWhenPillsChange() {
        let sidebar = SidebarViewController(palette: .dark)
        sidebar.loadView()
        let working = SessionInfo(id: "b", agent: "claude", agentState: "working")
        sidebar.update(sessions: [SessionInfo(id: "a"), working, SessionInfo(id: "c")], activeID: "a", unread: ["c"])
        #expect(sidebar.rows.map(\.id) == ["a", "b", "c"])
        var blocked = working
        blocked.agentState = "blocked"
        sidebar.update(sessions: [SessionInfo(id: "a"), blocked, SessionInfo(id: "c")], activeID: "a", unread: ["c"])
        #expect(sidebar.rows.map(\.id) == ["a", "b", "c"])
        #expect(sidebar.rows[1].pill?.kind == .blocked)
        #expect(sidebar.rows[2].isUnread)
        #expect(sidebar.rows[0].isActive)
    }
}
