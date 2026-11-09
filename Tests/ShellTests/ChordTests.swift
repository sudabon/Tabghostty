import AppKit
import DaemonClient
import Testing
import TerminalCore
@testable import Shell

/// spec: keyboard-shortcuts「Prefix chord for tab navigation」「Pending chord is visible and cancellable」（tasks 6.2）。
@MainActor
@Suite(.serialized) struct ChordTests {
    private let ctrlJ = (characters: "\n", keyCode: UInt16(0x26), ignoring: "j", flags: NSEvent.ModifierFlags.control)

    private func enabledSettings() -> TabSettings {
        TabSettings(keyBindings: KeyBindings(enabled: true))
    }

    private func pressCtrlJ(_ harness: ShellHarness) {
        harness.terminalView.keyDown(with: harness.key(ctrlJ.characters, keyCode: ctrlJ.keyCode, ignoring: ctrlJ.ignoring, flags: ctrlJ.flags))
    }

    private func press(_ harness: ShellHarness, _ character: String, keyCode: UInt16) {
        harness.terminalView.keyDown(with: harness.key(character, keyCode: keyCode))
    }

    private func settledInput(_ harness: ShellHarness) async throws -> [UInt8] {
        try await Task.sleep(for: .milliseconds(60))
        return harness.sink.inputBytes
    }

    /// 入力が届くまで待ってから読む（Thread Sanitizer 付きでは遅くなる）。
    private func waitForInput(_ harness: ShellHarness, count: Int) async throws -> [UInt8] {
        _ = await waitUntil { harness.sink.inputBytes.count >= count }
        return try await settledInput(harness)
    }

    // Scenario: Next tab — 最後のタブで Control-J → N なら先頭へ。どちらのキーも端末に届かない。
    @Test func nextWrapsAroundAndNeitherKeyReachesTheTerminal() async throws {
        let harness = try ShellHarness(settings: enabledSettings())
        await harness.liveSessions([session("a"), session("b"), session("c")])
        harness.shell.select("c")
        harness.sink.removeAll()
        var indicator: [String?] = []
        harness.shell.onPendingChordChange = { indicator.append($0) }

        pressCtrlJ(harness)
        #expect(harness.shell.chord.isPending)
        #expect(indicator == ["Ctrl+J …"])
        press(harness, "n", keyCode: 0x2D)
        #expect(harness.store.activeSessionID == "a")
        #expect(!harness.shell.chord.isPending)
        #expect(indicator == ["Ctrl+J …", nil])

        // P で前のタブ（先頭なら最後へ）。
        pressCtrlJ(harness)
        press(harness, "p", keyCode: 0x23)
        #expect(harness.store.activeSessionID == "c")
        #expect(try await settledInput(harness).isEmpty)
        #expect(harness.terminalView.controller?.sid == "c")
    }

    // Scenario: Cancel — Control-J → X は取り消し。タブは変わらず、X も送らない。
    @Test func otherKeysCancelWithoutReachingTheTerminal() async throws {
        let harness = try ShellHarness(settings: enabledSettings())
        await harness.liveSessions([session("a"), session("b")])
        harness.sink.removeAll()

        pressCtrlJ(harness)
        press(harness, "x", keyCode: 0x07)
        #expect(harness.store.activeSessionID == "a")
        #expect(!harness.shell.chord.isPending)
        // Escape も取り消し。
        pressCtrlJ(harness)
        press(harness, "\u{1b}", keyCode: 0x35)
        #expect(!harness.shell.chord.isPending)
        #expect(try await settledInput(harness).isEmpty)

        // 保留していなければ、ふつうに送る。
        press(harness, "x", keyCode: 0x07)
        #expect(try await waitForInput(harness, count: 1) == Array("x".utf8))
    }

    // Scenario: Disabled passthrough — 無効なら Control-J は 0x0a として届く。
    @Test func disabledChordsPassEveryKeyThrough() async throws {
        let harness = try ShellHarness()
        await harness.liveSessions([session("a")])
        harness.sink.removeAll()
        pressCtrlJ(harness)
        #expect(!harness.shell.chord.isPending)
        #expect(try await waitForInput(harness, count: 1) == [0x0a])
    }

    // 検証に通らない設定（予約されたプレフィックス）では、コードを使わない。
    @Test func invalidBindingsAreNotUsed() async throws {
        let harness = try ShellHarness(settings: TabSettings(keyBindings: KeyBindings(enabled: true, prefix: "j")))
        await harness.liveSessions([session("a")])
        harness.sink.removeAll()
        press(harness, "j", keyCode: 0x26)
        #expect(!harness.shell.chord.isPending)
        #expect(try await waitForInput(harness, count: 1) == Array("j".utf8))
    }

    // トグルのキーでサイドバーを隠し、端末の幅が広がる。
    @Test func toggleKeyCollapsesTheSidebar() async throws {
        let harness = try ShellHarness(settings: enabledSettings())
        await harness.liveSessions([session("a")])
        pressCtrlJ(harness)
        press(harness, "j", keyCode: 0x26)
        #expect(await waitUntil { harness.shell.splitViewController.isSidebarCollapsed })
    }

    // Scenario: Timeout — 3 秒（テストでは短くする）で取り消し、次のキーは端末に届く。
    @Test func pendingChordTimesOut() async throws {
        let harness = try ShellHarness(settings: enabledSettings(), chordTimeout: 0.1)
        await harness.liveSessions([session("a"), session("b")])
        harness.sink.removeAll()
        var indicator: [String?] = []
        harness.shell.onPendingChordChange = { indicator.append($0) }

        pressCtrlJ(harness)
        #expect(harness.shell.chord.isPending)
        #expect(await waitUntil { !harness.shell.chord.isPending })
        #expect(indicator == ["Ctrl+J …", nil])
        press(harness, "n", keyCode: 0x2D)
        #expect(harness.store.activeSessionID == "a")
        #expect(try await waitForInput(harness, count: 1) == Array("n".utf8))
    }

    // プレフィックスをもう一度押すと、時間を数え直す。
    @Test func prefixAgainRestartsTheTimer() async throws {
        let harness = try ShellHarness(settings: enabledSettings(), chordTimeout: 0.3)
        await harness.liveSessions([session("a"), session("b")])
        pressCtrlJ(harness)
        try await Task.sleep(for: .milliseconds(200))
        pressCtrlJ(harness)
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.shell.chord.isPending)
        press(harness, "n", keyCode: 0x2D)
        #expect(harness.store.activeSessionID == "b")
    }

    // ウィンドウがフォーカスを失ったとき・シートを開いたときに取り消す。
    @Test func resigningKeyOrOpeningASheetCancels() async throws {
        let harness = try ShellHarness(settings: enabledSettings())
        await harness.liveSessions([session("a")])

        pressCtrlJ(harness)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: harness.window)
        #expect(!harness.shell.chord.isPending)

        pressCtrlJ(harness)
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: harness.window)
        #expect(!harness.shell.chord.isPending)
    }

    // Scenario: Memo editor open — メモの編集シートを開いていると、コードを受け付けない。
    @Test func chordsAreSuspendedWhileTheMemoEditorIsOpen() async throws {
        let harness = try ShellHarness(settings: enabledSettings())
        await harness.liveSessions([session("a")])
        harness.shell.editMemo("a")
        let editor = try #require(harness.shell.activeMemoEditor)
        harness.sink.removeAll()

        pressCtrlJ(harness)
        #expect(!harness.shell.chord.isPending)
        editor.cancel(nil)
        // 閉じたら、また受け付ける。
        pressCtrlJ(harness)
        #expect(harness.shell.chord.isPending)
    }

    // プレフィックスの J を離したことも、端末に届かない（kitty keyboard protocol の離したキーの報告）。
    @Test func releaseOfTheConsumedPrefixIsNotReported() async throws {
        let harness = try ShellHarness(settings: enabledSettings())
        await harness.liveSessions([session("a")])
        await harness.coordinator.controller(for: "a")?.receiveOutput(Array("\u{1b}[>2u".utf8))
        harness.sink.removeAll()

        pressCtrlJ(harness)
        let release = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\n", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 0x26
        )!
        harness.terminalView.keyUp(with: release)
        #expect(try await settledInput(harness).isEmpty)
    }
}
