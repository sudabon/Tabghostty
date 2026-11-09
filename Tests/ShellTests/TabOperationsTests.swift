import AppKit
import DaemonClient
import Testing
import TerminalCore
@testable import Shell

/// spec: tab-operations / tab-sidebar / keyboard-shortcuts のうち、`TabShellController` とサイドバーで確かめられるもの。
@MainActor
@Suite(.serialized) struct TabOperationsTests {
    // MARK: - 5.1 選択と、作る・複製・再起動

    // Scenario: Switch tabs — 選ぶと、そのタブの端末を replay せずに表示し、フォーカスを移す。
    @Test func selectingShowsTheSessionAndFocusesTheTerminal() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b")])
        harness.window.makeFirstResponder(nil)
        harness.sink.removeAll()

        harness.shell.select("b")
        #expect(harness.store.activeSessionID == "b")
        #expect(harness.terminalView.controller === harness.coordinator.controller(for: "b"))
        #expect(harness.window.firstResponder === harness.terminalView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!harness.sink.frames.contains { if case .attach = $0 { true } else { false } })
        // 一覧に無いセッションは選ばない。
        harness.shell.select("zzz")
        #expect(harness.store.activeSessionID == "b")
    }

    @Test func createDuplicateAndRestartGoThroughTheAPI() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("dead", state: "exited")])

        harness.shell.createTab()
        #expect(await waitUntil { harness.store.activeSessionID == "created" })
        harness.shell.perform(.duplicate, on: "a")
        #expect(await waitUntil { harness.store.activeSessionID == "duplicated" })
        harness.shell.perform(.restart, on: "a")
        harness.shell.perform(.restart, on: "dead")
        #expect(await waitUntil { harness.store.activeSessionID == "restarted" })
        #expect(harness.api.calls == ["create", "duplicate:a", "restart:dead"])
    }

    // MARK: - 6.3 Command-1〜9

    // Scenario: Select second tab / Missing position
    @Test func positionShortcutsSelectExistingTabsOnly() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b"), session("c")])
        harness.sink.removeAll()

        #expect(harness.shell.selectTab(atPosition: 2))
        #expect(harness.store.activeSessionID == "b")
        #expect(harness.shell.canSelectTab(atPosition: 3))
        #expect(!harness.shell.canSelectTab(atPosition: 5))
        #expect(!harness.shell.selectTab(atPosition: 5))
        #expect(!harness.shell.selectTab(atPosition: 0))
        #expect(harness.store.activeSessionID == "b")
        try await Task.sleep(for: .milliseconds(50))
        // どのセッションにも何も送らない（アクティブにしたときのサイズの送り直しだけ）。
        #expect(harness.sink.inputBytes.isEmpty)
    }

    // MARK: - 5.2 閉じる・最後のタブ

    // Scenario: Confirm running / Idle tab
    @Test func closingARunningTabAsksFirst() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("dev", state: "running"), session("idle")])
        var asked: [String] = []
        var answer = false
        harness.shell.confirmClose = { session, completion in
            asked.append(session.id)
            completion(answer)
        }

        harness.shell.requestClose("dev")
        try await Task.sleep(for: .milliseconds(50))
        #expect(asked == ["dev"])
        #expect(harness.api.calls.isEmpty)

        answer = true
        harness.shell.requestClose("dev")
        #expect(await waitUntil { harness.api.calls == ["delete:dev"] })

        harness.shell.perform(.close, on: "idle")
        #expect(await waitUntil { harness.api.calls == ["delete:dev", "delete:idle"] })
        #expect(asked == ["dev", "dev"])
    }

    @Test func confirmationCanBeTurnedOff() async throws {
        let harness = try ShellHarness(settings: TabSettings(confirmCloseRunning: false))
        await harness.liveSessions([session("dev", state: "running")])
        harness.shell.confirmClose = { _, _ in Issue.record("must not ask") }
        harness.shell.requestClose("dev")
        #expect(await waitUntil { harness.api.calls == ["delete:dev"] })
    }

    @Test func closeConfirmationDecision() {
        #expect(TabPolicy.needsCloseConfirmation(session("a", state: "running"), confirmCloseRunning: true))
        #expect(!TabPolicy.needsCloseConfirmation(session("a", state: "idle"), confirmCloseRunning: true))
        #expect(!TabPolicy.needsCloseConfirmation(session("a", state: "exited"), confirmCloseRunning: true))
        #expect(!TabPolicy.needsCloseConfirmation(session("a", state: "running"), confirmCloseRunning: false))
        #expect(TabPolicy.closeConfirmationMessage == "このタブは実行中です。閉じますか？")
    }

    @Test func lastTabOutcomeDecision() {
        #expect(TabPolicy.lastTabOutcome(previousCount: 1, currentCount: 0, quitWhenNoTabs: true) == .quit)
        #expect(TabPolicy.lastTabOutcome(previousCount: 3, currentCount: 0, quitWhenNoTabs: true) == .quit)
        #expect(TabPolicy.lastTabOutcome(previousCount: 1, currentCount: 0, quitWhenNoTabs: false) == .showEmptyState)
        // 起動したときから 0 件、0 件のまま、0 件以外では何もしない。
        #expect(TabPolicy.lastTabOutcome(previousCount: nil, currentCount: 0, quitWhenNoTabs: true) == .none)
        #expect(TabPolicy.lastTabOutcome(previousCount: 0, currentCount: 0, quitWhenNoTabs: true) == .none)
        #expect(TabPolicy.lastTabOutcome(previousCount: 2, currentCount: 1, quitWhenNoTabs: true) == .none)
    }

    // デーモンが起動し直して、再接続した後の一覧が空でも、終了しない（利用者がタブを閉じたのではない）。
    @Test func reconnectingToAnEmptyDaemonDoesNotQuit() async throws {
        let harness = try ShellHarness()
        var quits = 0
        var messages: [String] = []
        harness.shell.onQuitRequested = { quits += 1 }
        harness.shell.onTransientMessage = { messages.append($0) }
        await harness.liveSessions([session("a")])

        harness.shell.connectionDidChange(connected: false)
        harness.shell.connectionDidChange(connected: true)
        await harness.deliver(.sessions([]))
        #expect(quits == 0)
        #expect(harness.shell.terminalArea.isEmptyStateVisible)
        #expect(messages.count == 1)

        // その後に利用者が作って閉じた最後のタブは、これまでどおり終了する。
        await harness.liveSessions([session("b")])
        #expect(!harness.shell.terminalArea.isEmptyStateVisible)
        await harness.deliver(.sessions([]))
        #expect(quits == 1)
    }

    // 再接続した後の一覧が届くまでの変化（同じ一覧のまま）では、何もしない。
    @Test func reconnectingKeepsTabsWhenTheDaemonStillHasThem() async throws {
        let harness = try ShellHarness()
        var quits = 0
        harness.shell.onQuitRequested = { quits += 1 }
        await harness.liveSessions([session("a")])
        harness.shell.connectionDidChange(connected: false)
        harness.shell.connectionDidChange(connected: true)
        await harness.deliver(.sessions([session("a")]))
        #expect(quits == 0)
        #expect(!harness.shell.terminalArea.isEmptyStateVisible)
        await harness.deliver(.sessions([]))
        #expect(quits == 1)
    }

    // Scenario: Quit on last close
    @Test func closingTheLastTabQuits() async throws {
        let harness = try ShellHarness()
        var quits = 0
        harness.shell.onQuitRequested = { quits += 1 }
        await harness.deliver(.sessions([]))
        #expect(quits == 0)
        await harness.liveSessions([session("a")])
        await harness.deliver(.sessions([]))
        #expect(quits == 1)
        #expect(!harness.shell.terminalArea.isEmptyStateVisible)
    }

    // Scenario: Empty state
    @Test func emptyStateWhenQuittingIsTurnedOff() async throws {
        let harness = try ShellHarness(settings: TabSettings(quitWhenNoTabs: false))
        var quits = 0
        harness.shell.onQuitRequested = { quits += 1 }
        await harness.liveSessions([session("a")])
        await harness.deliver(.sessions([]))
        #expect(quits == 0)
        #expect(harness.shell.terminalArea.isEmptyStateVisible)
        #expect(harness.terminalView.controller == nil)

        // 「＋ 新規タブ」で作る。
        harness.shell.terminalArea.onNewTab?()
        #expect(await waitUntil { harness.api.calls == ["create"] })
        await harness.liveSessions([session("created")])
        #expect(!harness.shell.terminalArea.isEmptyStateVisible)
    }

    // MARK: - 5.3 並べ替え

    // Scenario: Reorder visible in browser（3 番目を先頭へ）
    @Test func reorderedIDsMoveOneTab() {
        let ids = ["a", "b", "c"]
        #expect(SidebarViewController.reorderedIDs(ids, moving: "c", toRow: 0) == ["c", "a", "b"])
        #expect(SidebarViewController.reorderedIDs(ids, moving: "a", toRow: 3) == ["b", "c", "a"])
        #expect(SidebarViewController.reorderedIDs(ids, moving: "a", toRow: 2) == ["b", "a", "c"])
        // 動かないなら送らない。
        #expect(SidebarViewController.reorderedIDs(ids, moving: "b", toRow: 1) == nil)
        #expect(SidebarViewController.reorderedIDs(ids, moving: "b", toRow: 2) == nil)
        #expect(SidebarViewController.reorderedIDs(ids, moving: "zzz", toRow: 0) == nil)
    }

    @Test func reorderSendsTheWholeListWithoutChangingTheLocalOrder() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b"), session("c")])
        harness.shell.sidebar.onReorder?(["c", "a", "b"])
        #expect(await waitUntil { harness.api.calls == ["order:c,a,b"] })
        #expect(harness.store.sessions.map(\.id) == ["a", "b", "c"])
        #expect(TabRowView.dragThreshold == 6)
    }

    // MARK: - 5.4 メモ

    // Scenario: Limit / Save memo（30 code point、前後の空白を削る）
    @Test func memoTextIsClampedByCodePointsAndTrimmed() {
        let exact = String(repeating: "あ", count: 30)
        #expect(MemoText.clamp(exact) == exact)
        #expect(MemoText.clamp(exact + "い") == exact)
        #expect(MemoText.length("CI") == 2)
        #expect(MemoText.length("あいう") == 3)
        #expect(MemoText.length("🙂🙂") == 2)
        #expect(MemoText.length(MemoText.clamp(String(repeating: "🙂", count: 31))) == 30)
        #expect(MemoText.remaining("") == 30)
        #expect(MemoText.remaining(exact) == 0)
        #expect(MemoText.normalizedForSave("  レビュー対応  ") == "レビュー対応")
        #expect(MemoText.normalizedForSave("\u{3000}全角\u{3000}") == "全角")
        #expect(MemoText.normalizedForSave("   ") == "")
    }

    // Scenario: Limit — 上限のメモの途中に入力・ペーストしても、31 文字目は受け付けない（もとの末尾の文字は消さない）。
    @Test func memoOverflowIsTrimmedFromTheInsertedTextNotTheTail() throws {
        let full = String(repeating: "a", count: 28) + "yz"
        // 2 文字目の後ろに 1 文字入力した: 入れた文字を捨て、カーソルは入れた位置のまま。
        let typed = try #require(MemoText.fit("aa" + "x" + String(full.dropFirst(2)), previous: full, caret: 3))
        #expect(typed.text == full)
        #expect(typed.caret == 2)
        // カーソルが分からなくても、変わっていない先頭と末尾から求める。
        #expect(MemoText.fit("aa" + "x" + String(full.dropFirst(2)), previous: full)?.text == full)
        // 25 文字のメモの途中に 10 文字ペーストした: 入る 5 文字だけ残し、末尾は残す。
        let previous = String(repeating: "a", count: 20) + "tail!"
        let pasted = String(previous.prefix(10)) + "0123456789" + String(previous.dropFirst(10))
        let fitted = try #require(MemoText.fit(pasted, previous: previous, caret: 20))
        #expect(fitted.text == String(previous.prefix(10)) + "01234" + String(previous.dropFirst(10)))
        #expect(fitted.text.hasSuffix("tail!"))
        #expect(fitted.caret == 15)
        // 上限に収まっていれば何もしない。
        #expect(MemoText.fit("short", previous: "shor") == nil)
        // code point で数え、カーソルは UTF-16 の位置。
        let emoji = String(repeating: "🙂", count: 30)
        let withExtra = try #require(MemoText.fit("🙂" + "🎉" + String(emoji.dropFirst()), previous: emoji, caret: 4))
        #expect(withExtra.text == emoji)
        #expect(withExtra.caret == 2)
        // 何もない状態から長い文字列を入れたら、先頭の 30 文字。
        #expect(MemoText.fit(String(repeating: "b", count: 40), previous: "")?.text == String(repeating: "b", count: 30))
    }

    @Test func memoSheetClampsSavesTrimmedAndStaysOpenOnFailure() async throws {
        var saved: [String] = []
        var fail = true
        let sheet = MemoEditorSheet(initialMemo: "old", palette: .dark) { memo in
            saved.append(memo)
            if fail { throw FakeSessionAPI.Failure() }
        }
        #expect(sheet.text == "old")
        #expect(sheet.remainingText == "残り 27")
        sheet.text = String(repeating: "a", count: 31)
        #expect(sheet.text == String(repeating: "a", count: 30))
        #expect(sheet.remainingText == "残り 0")

        sheet.text = "  レビュー対応  "
        sheet.saveMemo(nil)
        #expect(await waitUntil { !sheet.isSaving })
        #expect(saved == ["レビュー対応"])
        // 失敗したら開いたまま、エラーを出す。
        #expect(sheet.errorText == "request failed")
        #expect(sheet.text == "  レビュー対応  ")

        fail = false
        sheet.text = "   "
        sheet.saveMemo(nil)
        #expect(await waitUntil { saved.count == 2 })
        // 空ならメモを消す。
        #expect(saved.last == "")
    }

    @Test func doubleClickOpensTheMemoSheetForThatTab() async throws {
        let harness = try ShellHarness()
        var withMemo = session("b")
        withMemo.memo = "レビュー対応"
        await harness.liveSessions([session("a"), withMemo])
        harness.shell.sidebar.onEditMemo?("b")
        #expect(harness.store.activeSessionID == "b")
        // オフスクリーンのウィンドウにはシートが付かないので、開いたエディタを直接見る。
        let editor = try #require(harness.shell.activeMemoEditor)
        #expect(editor.window?.title == "タブメモ")
        #expect(harness.shell.sidebar.isMemoEditorOpen)
        #expect(editor.text == "レビュー対応")
        editor.cancel(nil)
        #expect(harness.shell.activeMemoEditor == nil)
        #expect(!harness.shell.sidebar.isMemoEditorOpen)
    }

    // MARK: - 5.5 右クリックメニューとミュート

    // Scenario: Menu items / Restart unavailable
    @Test func contextMenuItems() {
        let exited = TabContextMenu.makeMenu(for: session("a", state: "exited")) { _ in }
        #expect(exited.items.map(\.title) == ["複製", "再起動", "閉じる", "通知"])
        #expect(exited.items.map(\.isEnabled) == [true, true, true, true])
        #expect(exited.items[3].state == .on)

        let running = TabContextMenu.makeMenu(for: session("a", state: "running", muted: true)) { _ in }
        #expect(running.items[1].isEnabled == false)
        #expect(running.items[3].state == .off)

        var chosen: [TabMenuItemState.Action] = []
        let menu = TabContextMenu.makeMenu(for: session("a")) { chosen.append($0) }
        menu.performActionForItem(at: 3)
        menu.performActionForItem(at: 0)
        #expect(chosen == [.toggleNotifications, .duplicate])
    }

    // Scenario: Mute / Failure
    @Test func muteToggleUpdatesImmediatelyAndRevertsOnFailure() async throws {
        let harness = try ShellHarness()
        var messages: [String] = []
        harness.coordinator.onTransientMessage = { messages.append($0) }
        await harness.liveSessions([session("a"), session("b")])

        harness.shell.perform(.toggleNotifications, on: "a")
        #expect(await waitUntil { harness.api.calls == ["mute:a:true"] })
        #expect(harness.store.sessions[0].notificationsMuted)
        let checked = TabContextMenu.items(for: harness.store.sessions[0])[3].isChecked
        #expect(checked == false)

        harness.api.failMute = true
        harness.shell.perform(.toggleNotifications, on: "b")
        #expect(await waitUntil { messages == ["request failed"] })
        #expect(harness.store.sessions[1].notificationsMuted == false)
    }

    // MARK: - 3.2 / 3.6 サイドバーの幅と折りたたみ

    // Scenario: Resize persists / Clamp
    @Test func sidebarWidthIsClampedAndCommittedOnRelease() async throws {
        let harness = try ShellHarness(settings: TabSettings(sidebarWidth: 240))
        var committed: [Int] = []
        harness.shell.onSidebarWidthCommitted = { committed.append($0) }
        let split = harness.shell.splitViewController
        #expect(abs(split.sidebarWidth - 240) < 1)

        split.simulateDividerDrag(to: 300)
        #expect(committed == [300])
        split.simulateDividerDrag(to: 900)
        #expect(abs(split.sidebarWidth - 480) < 1)
        #expect(committed == [300, 480])
        split.simulateDividerDrag(to: 20)
        #expect(abs(split.sidebarWidth - 160) < 1)
        #expect(committed == [300, 480, 160])
        // 範囲の外の設定値も収める。
        #expect(ShellSplitViewController.clampedWidth(1000) == 480)
        #expect(ShellSplitViewController.clampedWidth(10) == 160)
    }

    // Scenario: Collapse from menu — 隠すと端末が広がって resize を送り、端末にフォーカスがある。
    @Test func collapsingTheSidebarResizesTheTerminalAndFocusesIt() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a"), session("b")])
        #expect(await waitUntil { harness.coordinator.viewGrid != nil })
        #expect(await waitUntil { harness.sink.resizes.count == 2 })
        let before = try #require(harness.coordinator.viewGrid)
        harness.sink.removeAll()
        harness.window.makeFirstResponder(nil)

        harness.shell.toggleSidebar(animated: false)
        harness.shell.splitViewController.view.layoutSubtreeIfNeeded()
        #expect(harness.shell.splitViewController.isSidebarCollapsed)
        #expect(harness.shell.terminalArea.isExpandButtonVisible)
        #expect(harness.window.firstResponder === harness.terminalView)
        #expect(await waitUntil { harness.sink.resizes.count == 2 })
        let after = try #require(harness.coordinator.viewGrid)
        #expect(after.cols > before.cols)
        #expect(Set(harness.sink.resizes) == ["a:\(after.cols)x\(after.rows)", "b:\(after.cols)x\(after.rows)"])

        // 展開ボタン（とメニュー）で戻す。
        harness.shell.toggleSidebar(animated: false)
        #expect(!harness.shell.splitViewController.isSidebarCollapsed)
        #expect(!harness.shell.terminalArea.isExpandButtonVisible)
    }

    // メニューとボタンが使う、アニメーション付きの折りたたみでも、端末が広がる（ドラッグでは折りたたまない設定でも）。
    @Test func animatedCollapseAlsoGrowsTheTerminal() async throws {
        let harness = try ShellHarness()
        let before = harness.terminalView.frame.width
        harness.shell.toggleSidebar(animated: true)
        #expect(await waitUntil {
            harness.shell.splitViewController.view.layoutSubtreeIfNeeded()
            return harness.terminalView.frame.width > before + 100
        })
        harness.shell.toggleSidebar(animated: true)
        #expect(await waitUntil {
            harness.shell.splitViewController.view.layoutSubtreeIfNeeded()
            return abs(harness.terminalView.frame.width - before) < 2
        })
    }

    // Scenario: Not persisted — 新しく作ると、サイドバーは表示されている。
    @Test func collapsedStateIsNotPersisted() throws {
        let first = try ShellHarness()
        first.shell.toggleSidebar(animated: false)
        #expect(first.shell.splitViewController.isSidebarCollapsed)
        let second = try ShellHarness()
        #expect(!second.shell.splitViewController.isSidebarCollapsed)
    }

    // MARK: - 3.5 メモのツールチップ

    // Scenario: Hover（1 秒のディレイ）と、メモの編集を開いたら隠すこと。
    @Test func memoTooltipAppearsAfterADelayAndHidesForTheEditor() async throws {
        let harness = try ShellHarness()
        var withMemo = session("a")
        withMemo.memo = "レビュー対応"
        await harness.liveSessions([withMemo, session("b")])
        let sidebar = harness.shell.sidebar
        let row = try #require(sidebar.rowView(at: 0))
        let plain = try #require(sidebar.rowView(at: 1))

        sidebar.tabRow(plain, hoverChanged: true)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!sidebar.isMemoTooltipVisible)
        sidebar.tabRow(plain, hoverChanged: false)

        sidebar.tabRow(row, hoverChanged: true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!sidebar.isMemoTooltipVisible)
        #expect(await waitUntil(timeout: .seconds(2)) { sidebar.isMemoTooltipVisible })
        #expect(sidebar.memoTooltipText == "レビュー対応")

        sidebar.isMemoEditorOpen = true
        #expect(!sidebar.isMemoTooltipVisible)
        sidebar.isMemoEditorOpen = false

        // ポインタが離れたら隠す・離れる前に 1 秒経たなければ出さない。
        sidebar.tabRow(row, hoverChanged: true)
        try await Task.sleep(for: .milliseconds(300))
        sidebar.tabRow(row, hoverChanged: false)
        try await Task.sleep(for: .milliseconds(1000))
        #expect(!sidebar.isMemoTooltipVisible)
    }
}
