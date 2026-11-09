import Foundation
import os
import Testing
@testable import TerminalCore

/// spec: terminal-input（phase2）のうち、端末とコントローラで確かめられるもの。
@Suite struct TerminalInputTests {
    private func liveController(_ sink: RecordingSink, maxScrollback: Int = 1000, clipboard: (any TerminalClipboard)? = nil) async throws -> TerminalController {
        let controller = try TerminalController(sid: "s1", maxScrollback: maxScrollback, colors: nil, sink: sink, clipboard: clipboard)
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()
        return controller
    }

    private func key(_ characters: String, keyCode: UInt16, ignoring: String? = nil, modifiers: KeyInput.Modifiers = []) -> KeyInput {
        KeyInput.mac(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            unshiftedCharacters: ignoring?.lowercased() ?? characters,
            modifiers: modifiers
        )!
    }

    // MARK: - Option キー（Requirement: Option key composes characters）

    // Scenario: Option character — US 配列の Option+2 は macOS が合成した `™` になる（ESC の前置きは付けない）。
    @Test func optionComposedCharacterIsSentAsIs() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10)
        let optionTwo = KeyInput.mac(
            keyCode: 0x13, characters: "™", charactersIgnoringModifiers: "2", unshiftedCharacters: "2", modifiers: .option
        )!
        #expect(optionTwo.consumedModifiers == .option)
        #expect(try terminal.encodeKey(optionTwo) == Array("™".utf8))

        let optionE = KeyInput.mac(
            keyCode: 0x0E, characters: "é", charactersIgnoringModifiers: "e", unshiftedCharacters: "e", modifiers: []
        )!
        #expect(try terminal.encodeKey(optionE) == Array("é".utf8))
    }

    // Scenario: Kitty keyboard protocol — Control+Shift+A を、キーと修飾キーが分かる形で報告する。
    @Test func kittyProtocolReportsKeyAndModifiers() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10)
        // CSI > 1 u: disambiguate escape codes
        terminal.write(bytes("\u{1b}[>1u"))
        let controlShiftA = key("\u{01}", keyCode: 0x00, ignoring: "A", modifiers: [.control, .shift])
        // 97 = 'a'、6 = 1 + Shift(1) + Ctrl(4)
        #expect(try terminal.encodeKey(controlShiftA) == bytes("\u{1b}[97;6u"))

        // 離したことは、プロトコルで求められたとき（フラグ 2）だけ報告する。
        let release = KeyInput.mac(
            keyCode: 0x00, characters: "a", charactersIgnoringModifiers: "a", unshiftedCharacters: "a", modifiers: [], action: .release
        )!
        #expect(try terminal.encodeKey(release).isEmpty)
        terminal.write(bytes("\u{1b}[=3u"))
        #expect(try terminal.encodeKey(release) == bytes("\u{1b}[97;1:3u"))
    }

    // 従来のエンコードでは、キーを離しても何も送らない。修飾キーだけを押しても何も送らない。
    @Test func releasesAndModifierKeysAreSilentWithoutKittyProtocol() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10)
        let release = KeyInput.mac(
            keyCode: 0x24, characters: "\r", charactersIgnoringModifiers: "\r", unshiftedCharacters: "\r", modifiers: [], action: .release
        )!
        #expect(try terminal.encodeKey(release).isEmpty)
        let shift = KeyInput.mac(keyCode: 0x38, characters: "", charactersIgnoringModifiers: "", unshiftedCharacters: "", modifiers: .shift)!
        #expect(try terminal.encodeKey(shift).isEmpty)
    }

    // MARK: - フォーカス（Requirement: Keyboard protocol and focus reporting — Scenario: Focus events）

    @MainActor
    @Test func focusChangesAreReportedOnlyWhenEnabled() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        controller.enqueueFocus(false)
        await controller.flushInput()
        #expect(sink.inputFrames.isEmpty)

        await controller.receiveOutput(bytes("\u{1b}[?1004h"))
        controller.enqueueFocus(false)
        controller.enqueueFocus(true)
        await controller.flushInput()
        #expect(sink.inputFrames == [bytes("\u{1b}[O\u{1b}[I")])
    }

    @MainActor
    @Test func focusIsNotReportedDuringReplay() async throws {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", maxScrollback: 100, colors: nil, sink: sink)
        await controller.attach()
        await controller.receiveReplay(bytes("\u{1b}[?1004h"), done: false)
        controller.enqueueFocus(true)
        await controller.flushInput()
        #expect(sink.inputFrames.isEmpty)
    }

    // MARK: - キー入力で最下部に戻る（Requirement: Typing returns to the bottom）

    // Scenario: Type while scrolled back
    @MainActor
    @Test func typingReturnsTheViewportToTheBottom() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes((0..<300).map { "line \($0)\r\n" }.joined()))
        let surface = MouseSurface.testSurface
        controller.enqueueScroll(ScrollInput(lines: 100, x: 10, y: 10, surface: surface))
        await controller.flushInput()
        #expect(await controller.withTerminal { $0.isViewportAtBottom } == false)
        #expect(sink.inputFrames.isEmpty)

        controller.enqueueKey(key("x", keyCode: 0x07))
        await controller.flushInput()
        #expect(sink.inputFrames == [bytes("x")])
        #expect(await controller.withTerminal { $0.isViewportAtBottom })
    }

    // 何も送らない入力（離したキー、報告しないマウスの移動）では最下部に戻らない。
    @MainActor
    @Test func inputThatSendsNothingKeepsTheViewport() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        await controller.receiveOutput(bytes((0..<300).map { "line \($0)\r\n" }.joined()))
        controller.enqueueScroll(ScrollInput(lines: 10, x: 10, y: 10, surface: .testSurface))
        controller.enqueueKey(KeyInput.mac(
            keyCode: 0x07, characters: "x", charactersIgnoringModifiers: "x", unshiftedCharacters: "x", modifiers: [], action: .release
        )!)
        await controller.flushInput()
        #expect(sink.inputFrames.isEmpty)
        #expect(await controller.withTerminal { $0.isViewportAtBottom } == false)
    }

    // テキスト（Shift+Enter、¥、IME の確定）はそのまま、キー入力と同じ順で送る。
    @MainActor
    @Test func textAndKeysKeepTheirOrder() async throws {
        let sink = RecordingSink()
        let controller = try await liveController(sink)
        controller.enqueueKey(key("a", keyCode: 0x00))
        controller.enqueueText("\\")
        controller.enqueueText("日本語")
        controller.enqueueText(shiftEnterSequence)
        controller.enqueueKey(key("b", keyCode: 0x0B))
        await controller.flushInput()
        #expect(sink.inputFrames == [bytes("a\\日本語\u{1b}\rb")])
    }

    // MARK: - Ctrl+V（Requirement: Control-V passes through）

    @Test func controlVIsSentAs0x16() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10)
        #expect(try terminal.encodeKey(key("\u{16}", keyCode: 0x09, ignoring: "v", modifiers: .control)) == [0x16])
        // bracketed paste が有効でも、Ctrl+V はペーストにしない。
        terminal.write(bytes("\u{1b}[?2004h"))
        #expect(try terminal.encodeKey(key("\u{16}", keyCode: 0x09, ignoring: "v", modifiers: .control)) == [0x16])
    }
}

extension MouseSurface {
    /// テスト用: 80 列 × 24 行、セル 16 × 34 px、余白 8 px。
    static let testSurface = MouseSurface(
        width: 16 * 80 + 16, height: 34 * 24 + 16, cellWidth: 16, cellHeight: 34,
        paddingTop: 8, paddingBottom: 8, paddingLeft: 8, paddingRight: 8, columns: 80
    )

    /// セル（0 始まり）の中央の surface 座標。
    func center(ofColumn column: Int, row: Int) -> (x: Double, y: Double) {
        (Double(paddingLeft + column * cellWidth + cellWidth / 2), Double(paddingTop + row * cellHeight + cellHeight / 2))
    }
}
