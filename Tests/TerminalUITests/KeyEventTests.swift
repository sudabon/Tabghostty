import AppKit
import os
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: terminal-input「Key events are encoded by the terminal's current modes」。
/// `NSEvent` → `KeyInput` → libghostty のキーエンコーダ、の変換表。
@MainActor
@Suite struct KeyEventTests {
    private func event(
        _ characters: String,
        keyCode: UInt16,
        ignoring: String? = nil,
        flags: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func encode(_ event: NSEvent, terminal: VTTerminal) throws -> [UInt8] {
        let input = try #require(KeyInput(event: event))
        return try terminal.encodeKey(input)
    }

    private let functionFlags: NSEvent.ModifierFlags = [.function, .numericPad]

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let characters: String
        let keyCode: UInt16
        let expected: String
        var testDescription: String { name }
    }

    nonisolated static let table: [Case] = [
        Case(name: "a", characters: "a", keyCode: 0x00, expected: "a"),
        Case(name: "A (shift)", characters: "A", keyCode: 0x00, expected: "A"),
        Case(name: "Enter", characters: "\r", keyCode: 0x24, expected: "\r"),
        Case(name: "Tab", characters: "\t", keyCode: 0x30, expected: "\t"),
        Case(name: "Backspace", characters: "\u{7f}", keyCode: 0x33, expected: "\u{7f}"),
        Case(name: "Escape", characters: "\u{1b}", keyCode: 0x35, expected: "\u{1b}"),
        Case(name: "Up", characters: "\u{F700}", keyCode: 0x7E, expected: "\u{1b}[A"),
        Case(name: "Down", characters: "\u{F701}", keyCode: 0x7D, expected: "\u{1b}[B"),
        Case(name: "Right", characters: "\u{F703}", keyCode: 0x7C, expected: "\u{1b}[C"),
        Case(name: "Left", characters: "\u{F702}", keyCode: 0x7B, expected: "\u{1b}[D"),
        Case(name: "Home", characters: "\u{F729}", keyCode: 0x73, expected: "\u{1b}[H"),
        Case(name: "End", characters: "\u{F72B}", keyCode: 0x77, expected: "\u{1b}[F"),
        Case(name: "PageUp", characters: "\u{F72C}", keyCode: 0x74, expected: "\u{1b}[5~"),
        Case(name: "PageDown", characters: "\u{F72D}", keyCode: 0x79, expected: "\u{1b}[6~"),
        Case(name: "Delete", characters: "\u{F728}", keyCode: 0x75, expected: "\u{1b}[3~"),
        Case(name: "F1", characters: "\u{F704}", keyCode: 0x7A, expected: "\u{1b}OP"),
        Case(name: "F2", characters: "\u{F705}", keyCode: 0x78, expected: "\u{1b}OQ"),
        Case(name: "F3", characters: "\u{F706}", keyCode: 0x63, expected: "\u{1b}OR"),
        Case(name: "F4", characters: "\u{F707}", keyCode: 0x76, expected: "\u{1b}OS"),
        Case(name: "F5", characters: "\u{F708}", keyCode: 0x60, expected: "\u{1b}[15~"),
        Case(name: "F6", characters: "\u{F709}", keyCode: 0x61, expected: "\u{1b}[17~"),
        Case(name: "F7", characters: "\u{F70A}", keyCode: 0x62, expected: "\u{1b}[18~"),
        Case(name: "F8", characters: "\u{F70B}", keyCode: 0x64, expected: "\u{1b}[19~"),
        Case(name: "F9", characters: "\u{F70C}", keyCode: 0x65, expected: "\u{1b}[20~"),
        Case(name: "F10", characters: "\u{F70D}", keyCode: 0x6D, expected: "\u{1b}[21~"),
        Case(name: "F11", characters: "\u{F70E}", keyCode: 0x67, expected: "\u{1b}[23~"),
        Case(name: "F12", characters: "\u{F70F}", keyCode: 0x6F, expected: "\u{1b}[24~"),
    ]

    @Test(arguments: table)
    func translationTable(_ entry: Case) throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10)
        let isFunctionKey = entry.characters.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } ?? false
        var flags: NSEvent.ModifierFlags = isFunctionKey ? functionFlags : []
        if entry.characters == "A" { flags.insert(.shift) }
        let bytes = try encode(event(entry.characters, keyCode: entry.keyCode, flags: flags), terminal: terminal)
        #expect(bytes == Array(entry.expected.utf8))
    }

    // Scenario: Interrupt（Ctrl+文字）
    @Test func controlLetters() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10)
        #expect(try encode(event("\u{03}", keyCode: 0x08, ignoring: "c", flags: .control), terminal: terminal) == [0x03])
        #expect(try encode(event("\u{01}", keyCode: 0x00, ignoring: "a", flags: .control), terminal: terminal) == [0x01])
        #expect(try encode(event("\u{1a}", keyCode: 0x06, ignoring: "z", flags: .control), terminal: terminal) == [0x1a])
        #expect(try encode(event("\u{04}", keyCode: 0x02, ignoring: "d", flags: .control), terminal: terminal) == [0x04])
    }

    // Scenario: Application cursor mode
    @Test func applicationCursorModeSendsSS3() throws {
        let terminal = try VTTerminal(cols: 80, rows: 24, maxScrollback: 10)
        terminal.write(Array("\u{1b}[?1h".utf8))
        let up = try encode(event("\u{F700}", keyCode: 0x7E, flags: functionFlags), terminal: terminal)
        #expect(up == Array("\u{1b}OA".utf8))
        terminal.write(Array("\u{1b}[?1l".utf8))
        #expect(try encode(event("\u{F700}", keyCode: 0x7E, flags: functionFlags), terminal: terminal) == Array("\u{1b}[A".utf8))
    }

    // Scenario: Typing a command / Command shortcuts are not typed
    @Test func viewSendsTypedKeysButNotCommandCombinations() async throws {
        let sink = RecordingSink()
        let controller = try TerminalController(sid: "s1", maxScrollback: 10, colors: nil, sink: sink)
        await controller.attach()
        await controller.receiveReplay([], done: true)
        sink.removeAll()

        let view = TerminalView(fontFamily: "Menlo", fontSize: 14, palette: .dark)
        view.controller = controller
        view.keyDown(with: event("q", keyCode: 0x0C, flags: .command))
        view.keyDown(with: event("l", keyCode: 0x25))
        view.keyDown(with: event("s", keyCode: 0x01))
        view.keyDown(with: event("\r", keyCode: 0x24))

        for _ in 0..<200 where sink.inputBytes.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(sink.inputBytes == [Array("ls\r".utf8)])
    }
}

final class RecordingSink: TerminalFrameSink, @unchecked Sendable {
    private let frames = OSAllocatedUnfairLock(initialState: [TerminalOutgoingFrame]())

    var inputBytes: [[UInt8]] {
        frames.withLock { frames in
            frames.compactMap { if case .input(_, let bytes) = $0 { return bytes } else { return nil } }
        }
    }

    func removeAll() { frames.withLock { $0.removeAll() } }

    func enqueue(_ frame: TerminalOutgoingFrame) -> Bool {
        frames.withLock { $0.append(frame) }
        return true
    }
}
