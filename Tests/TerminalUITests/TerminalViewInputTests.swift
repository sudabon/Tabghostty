import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: terminal-input / terminal-clipboard / terminal-mouse（phase2）のうち、ビューで確かめられるもの。
@MainActor
@Suite struct TerminalViewInputTests {
    private struct Fixture {
        let view: TerminalView
        let controller: TerminalController
        let sink: RecordingSink
        let pasteboard: NSPasteboard
        let window: NSWindow
    }

    /// live の端末を表示したビュー（オフスクリーンのウィンドウに置く）。
    private func makeFixture(output: String = "", settings: TerminalInputSettings = TerminalInputSettings()) async throws -> Fixture {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", cols: 40, rows: 6, maxScrollback: 100, colors: nil, sink: sink)
        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark)
        let size = NSSize(
            width: 2 * GridGeometry.padding + 40 * view.metrics.width,
            height: 2 * GridGeometry.padding + 6 * view.metrics.height
        )
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        await controller.setViewGrid(.init(cols: 40, rows: 6, cellWidthPx: view.metrics.widthPx, cellHeightPx: view.metrics.heightPx))
        await controller.attach()
        await controller.receiveReplay(Array(output.utf8), done: true)
        sink.removeAll()

        view.controller = controller
        view.inputSettings = settings
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Tabghostty.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        view.pasteboard = pasteboard
        view.apply(try #require(await controller.makeSnapshot(forceFull: true)))
        return Fixture(view: view, controller: controller, sink: sink, pasteboard: pasteboard, window: window)
    }

    private func key(
        _ characters: String,
        keyCode: UInt16,
        ignoring: String? = nil,
        flags: NSEvent.ModifierFlags = [],
        type: NSEvent.EventType = .keyDown
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: keyCode
        )!
    }

    /// 送られた入力（全フレームをつなげたもの）。少し待ってから読む。
    private func sentInput(_ sink: RecordingSink, settle: Duration = .milliseconds(40)) async throws -> [UInt8] {
        try await Task.sleep(for: settle)
        return Array(sink.inputBytes.joined())
    }

    private func waitForInput(_ sink: RecordingSink) async throws -> [UInt8] {
        for _ in 0..<200 where sink.inputBytes.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try await sentInput(sink)
    }

    private func waitForPasteboard(_ pasteboard: NSPasteboard, toBe expected: String) async throws -> String? {
        for _ in 0..<200 where pasteboard.string(forType: .string) != expected {
            try await Task.sleep(for: .milliseconds(5))
        }
        return pasteboard.string(forType: .string)
    }

    // MARK: - Shift+Enter と ¥（spec: terminal-input）

    // Scenario: Claude Code newline / Plain Enter submits
    @Test func shiftEnterSendsEscCRAndEnterSubmits() async throws {
        let fixture = try await makeFixture()
        fixture.view.keyDown(with: key("\r", keyCode: 0x24, flags: .shift))
        fixture.view.keyDown(with: key("\r", keyCode: 0x24))
        #expect(try await waitForInput(fixture.sink) == Array("\u{1b}\r\r".utf8))
    }

    // Scenario: Disabled — キーエンコーダの通常のエンコードになる（libghostty は Shift+Enter を `CSI 27;2;13~` にする）。
    @Test func shiftEnterIsEncodedNormallyWhenDisabled() async throws {
        let fixture = try await makeFixture(settings: TerminalInputSettings(shiftEnterNewline: false))
        let event = key("\r", keyCode: 0x24, flags: .shift)
        let encoded = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10).encodeKey(try #require(KeyInput(event: event)))
        fixture.view.keyDown(with: event)
        let sent = try await waitForInput(fixture.sink)
        #expect(sent == encoded)
        #expect(sent != Array("\u{1b}\r".utf8))
    }

    // Scenario: JIS keyboard / Modified yen
    @Test func yenKeyTypesABackslash() async throws {
        let fixture = try await makeFixture()
        fixture.view.keyDown(with: key("¥", keyCode: 0x5D))
        #expect(try await waitForInput(fixture.sink) == Array("\\".utf8))

        fixture.sink.removeAll()
        fixture.view.keyDown(with: key("¥", keyCode: 0x5D, flags: .option))
        #expect(try await waitForInput(fixture.sink) == Array("¥".utf8))
    }

    // Scenario: Option character（US 配列の Option+2）
    @Test func optionComposedCharacterIsSent() async throws {
        let fixture = try await makeFixture()
        fixture.view.keyDown(with: key("™", keyCode: 0x13, ignoring: "2", flags: .option))
        #expect(try await waitForInput(fixture.sink) == Array("™".utf8))
    }

    // MARK: - IME（Requirement: Input method composition）

    // Scenario: Japanese input — 確定した文字列だけが届き、確定の Enter は送らない。
    @Test func onlyCommittedTextIsSent() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        view.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 4))
        // 変換中の Backspace と Enter は IME のもの（セッションには送らない）。
        view.keyDown(with: key("\u{7f}", keyCode: 0x33))
        view.keyDown(with: key("\r", keyCode: 0x24))
        view.setMarkedText("日本語", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await sentInput(fixture.sink).isEmpty)

        view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText() == false)
        #expect(try await waitForInput(fixture.sink) == Array("日本語".utf8))
    }

    // Scenario: Cancel composition
    // IME が確定してから、そのキーをコマンドとして返す（韓国語の入力の Return など）: 確定した文字列の後に、そのキーを送る。
    @Test func aKeyPassedBackAfterTheIMECommitsIsSentAfterTheText() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        view.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyEventInterpreter = { [unowned view] _ in
            view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
            view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        }
        view.keyDown(with: key("\r", keyCode: 0x24))
        #expect(try await waitForInput(fixture.sink) == Array("한\r".utf8))
    }

    // 変換を確定する Return（日本語の入力）: IME はキーを返さないので、確定した文字列だけを送る（改行は送らない）。
    @Test func aReturnThatOnlyCommitsTheConversionSendsOnlyTheText() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        view.setMarkedText("日本語", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyEventInterpreter = { [unowned view] _ in
            view.insertText("日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        view.keyDown(with: key("\r", keyCode: 0x24))
        #expect(try await waitForInput(fixture.sink) == Array("日本語".utf8))
    }

    // IME がキーを返しても、まだ変換中なら送らない（IME の中で使われたキー）。
    @Test func aKeyPassedBackWhileStillComposingIsNotSent() async throws {
        let fixture = try await makeFixture()
        let view = fixture.view
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.keyEventInterpreter = { [unowned view] _ in
            view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        }
        view.keyDown(with: key("\u{F701}", keyCode: 0x7D))
        #expect(try await sentInput(fixture.sink).isEmpty)
        #expect(view.hasMarkedText())
    }

    @Test func cancelledCompositionSendsNothing() async throws {
        let fixture = try await makeFixture()
        fixture.view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        fixture.view.keyDown(with: key("\u{1b}", keyCode: 0x35))
        fixture.view.unmarkText()
        #expect(fixture.view.hasMarkedText() == false)
        #expect(try await sentInput(fixture.sink).isEmpty)
    }

    // IME の確定は ¥ を書き換えない（Scenario: Pasted yen と同じく、打ったキーだけを書き換える）。
    @Test func committedYenIsNotRewritten() async throws {
        let fixture = try await makeFixture()
        fixture.view.insertText("¥", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(try await waitForInput(fixture.sink) == Array("¥".utf8))
    }

    // Scenario: Candidate window position — 候補のウィンドウはカーソルのセル（から未確定の文字列の位置まで進めたところ）に出す。
    @Test func candidateWindowFollowsTheCursor() async throws {
        let fixture = try await makeFixture(output: "\r\n\r\n\r\n\r\n$ ")
        let view = fixture.view
        let cursor = try #require(view.cursor)
        #expect(cursor.x == 2 && cursor.y == 4)
        #expect(view.markedTextRect(upTo: 0) == view.cellRect(x: 2, y: 4))

        view.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        // 2 セル幅の文字が 2 つ（4 セル）進んだところ。
        #expect(view.markedTextRect(upTo: 2) == view.cellRect(x: 6, y: 4))
        #expect(view.markedTextRect(upTo: 1) == view.cellRect(x: 4, y: 4))

        let screenRect = view.firstRect(forCharacterRange: NSRange(location: 2, length: 0), actualRange: nil)
        let expected = fixture.window.convertToScreen(view.convert(view.cellRect(x: 6, y: 4), to: nil))
        #expect(screenRect == expected)
    }

    // MARK: - Ctrl+V と Command-C（spec: terminal-clipboard）

    // Scenario: Agent image paste — Ctrl+V は 0x16 を送り、ペーストしない。
    @Test func controlVSends0x16() async throws {
        let fixture = try await makeFixture()
        fixture.pasteboard.setString("should not be pasted", forType: .string)
        fixture.view.keyDown(with: key("\u{16}", keyCode: 0x09, ignoring: "v", flags: .control))
        #expect(try await waitForInput(fixture.sink) == [0x16])
    }

    // Scenario: No SIGINT from Command-C / Ctrl+C は 0x03 を送ってコピーしない / 離したキーは無視する。
    @Test func commandCIsNeverSentAndControlCIsNotACopy() async throws {
        let fixture = try await makeFixture(output: "hello")
        fixture.pasteboard.setString("sentinel", forType: .string)
        fixture.view.keyDown(with: key("c", keyCode: 0x08, flags: .command))
        fixture.view.keyUp(with: key("c", keyCode: 0x08, flags: .command, type: .keyUp))
        fixture.view.copy(nil)
        #expect(try await sentInput(fixture.sink).isEmpty)
        #expect(fixture.pasteboard.string(forType: .string) == "sentinel")

        fixture.view.keyDown(with: key("\u{03}", keyCode: 0x08, ignoring: "c", flags: .control))
        #expect(try await waitForInput(fixture.sink) == [0x03])
        #expect(fixture.pasteboard.string(forType: .string) == "sentinel")
    }

    // MARK: - コピー（Requirement: Copy with Command-C / Copy on select）

    private func mouse(_ type: NSEvent.EventType, _ view: TerminalView, column: Int, row: Int, right: Bool = false, flags: NSEvent.ModifierFlags = [], time: TimeInterval = 1) -> NSEvent {
        let metrics = view.metrics
        let x = GridGeometry.padding + (CGFloat(column) + (right ? 0.95 : 0.5)) * metrics.width
        let y = GridGeometry.padding + (CGFloat(row) + 0.5) * metrics.height
        let inWindow = view.convert(NSPoint(x: x, y: y), to: nil)
        return NSEvent.mouseEvent(
            with: type, location: inWindow, modifierFlags: flags, timestamp: time, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func dragSelect(_ view: TerminalView, from: (Int, Int), to: (Int, Int), flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, view, column: from.0, row: from.1, flags: flags))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, column: to.0, row: to.1, right: true, flags: flags))
        view.mouseUp(with: mouse(.leftMouseUp, view, column: to.0, row: to.1, right: true, flags: flags))
    }

    // Scenario: Copy selection
    @Test func commandCCopiesTheSelection() async throws {
        let fixture = try await makeFixture(output: "\u{1b}[32mhello\u{1b}[0m world")
        dragSelect(fixture.view, from: (0, 0), to: (4, 0))
        fixture.view.copy(nil)
        #expect(try await waitForPasteboard(fixture.pasteboard, toBe: "hello") == "hello")
        #expect(try await sentInput(fixture.sink).isEmpty)
    }

    // Scenario: Enabled（copy_on_select）
    @Test func copyOnSelectCopiesWhenTheSelectionEnds() async throws {
        let fixture = try await makeFixture(output: "hello world", settings: TerminalInputSettings(copyOnSelect: true))
        dragSelect(fixture.view, from: (6, 0), to: (10, 0))
        #expect(try await waitForPasteboard(fixture.pasteboard, toBe: "world") == "world")
    }

    // copy_on_select が false（既定）なら、選択しても pasteboard は変わらない。
    @Test func selectingDoesNotTouchThePasteboardByDefault() async throws {
        let fixture = try await makeFixture(output: "hello world")
        fixture.pasteboard.setString("sentinel", forType: .string)
        dragSelect(fixture.view, from: (6, 0), to: (10, 0))
        #expect(await fixture.controller.selectionText() == "world")
        #expect(fixture.pasteboard.string(forType: .string) == "sentinel")
    }

    // MARK: - マウスの報告と選択の使い分け（spec: terminal-mouse）

    // Scenario: Click in vim / Shift overrides mouse reporting
    @Test func clicksAreReportedUnlessShiftIsHeld() async throws {
        let fixture = try await makeFixture(output: "hello world\u{1b}[?1000h\u{1b}[?1006h")
        let view = fixture.view
        view.mouseDown(with: mouse(.leftMouseDown, view, column: 9, row: 4))
        view.mouseUp(with: mouse(.leftMouseUp, view, column: 9, row: 4))
        #expect(try await waitForInput(fixture.sink) == Array("\u{1b}[<0;10;5M\u{1b}[<0;10;5m".utf8))

        fixture.sink.removeAll()
        dragSelect(view, from: (0, 0), to: (4, 0), flags: .shift)
        #expect(await fixture.controller.selectionText() == "hello")
        #expect(try await sentInput(fixture.sink).isEmpty)
    }

    // MARK: - ペースト（Requirement: Paste with Command-V）

    @Test func pasteSendsThePasteboardText() async throws {
        let fixture = try await makeFixture(output: "\u{1b}[?2004h")
        fixture.pasteboard.setString("echo one\necho two", forType: .string)
        fixture.view.paste(nil)
        #expect(try await waitForInput(fixture.sink) == Array("\u{1b}[200~echo one\recho two\u{1b}[201~".utf8))
    }

    // Scenario: Unsafe paste confirmation / Cancelled unsafe paste
    @Test(arguments: [false, true])
    func unsafePasteIsSentOnlyWhenConfirmed(confirm: Bool) async throws {
        let fixture = try await makeFixture()
        var asked: [String] = []
        fixture.view.confirmUnsafePaste = { text, completion in
            asked.append(text)
            completion(confirm)
        }
        fixture.pasteboard.setString("rm -rf build\nls", forType: .string)
        fixture.view.paste(nil)
        if confirm {
            #expect(try await waitForInput(fixture.sink) == Array("rm -rf build\rls".utf8))
        } else {
            // 確認を求められるまで待ってから、何も送っていないことを確かめる（Thread Sanitizer 付きでは遅くなる）。
            for _ in 0..<400 where asked.isEmpty {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(try await sentInput(fixture.sink, settle: .milliseconds(80)).isEmpty)
        }
        #expect(asked == ["rm -rf build\nls"])
    }

    // MARK: - Edit メニューとテキストフィールド（Requirement: Edit menu）

    /// 応答チェーンをたどって、アクションを受け取るオブジェクトを探す（`NSApp.sendAction(_:to:nil, from:)` と同じ順）。
    private func target(for action: Selector, in window: NSWindow) -> NSResponder? {
        var responder = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    // テキストフィールドにフォーカスがあれば、Copy / Paste はフィールドの標準の動作になる。
    @Test func copyAndPasteGoToTheFocusedTextField() async throws {
        let fixture = try await makeFixture()
        let container = NSView(frame: fixture.view.frame)
        fixture.window.contentView = container
        container.addSubview(fixture.view)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        container.addSubview(field)

        #expect(fixture.window.makeFirstResponder(fixture.view))
        #expect(target(for: #selector(NSText.copy(_:)), in: fixture.window) === fixture.view)
        #expect(target(for: #selector(NSText.paste(_:)), in: fixture.window) === fixture.view)

        #expect(fixture.window.makeFirstResponder(field))
        let copyTarget = target(for: #selector(NSText.copy(_:)), in: fixture.window)
        #expect(copyTarget != nil)
        #expect(copyTarget !== fixture.view)
        #expect(target(for: #selector(NSText.paste(_:)), in: fixture.window) !== fixture.view)
    }

    // 変換中は Copy / Paste を使えない。
    @Test func copyAndPasteAreDisabledDuringComposition() async throws {
        let fixture = try await makeFixture(output: "hello")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(fixture.view.validateMenuItem(copyItem))
        #expect(fixture.view.validateMenuItem(pasteItem))

        fixture.view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fixture.view.validateMenuItem(copyItem) == false)
        #expect(fixture.view.validateMenuItem(pasteItem) == false)
        fixture.pasteboard.setString("text", forType: .string)
        fixture.view.paste(nil)
        #expect(try await sentInput(fixture.sink).isEmpty)
    }
}
