import Testing
@testable import TerminalCore

/// spec: terminal-input「Shift+Enter sends a newline sequence」「Yen key types a backslash」。
/// webtabinal `web/tests/terminal-input.test.ts` の Shift+Enter と ¥ のケースを移植したもの。
@Suite struct KeyClassifierTests {
    private let enabled = KeySettings(shiftEnterNewline: true)
    private let disabled = KeySettings(shiftEnterNewline: false)

    private func enter(
        _ modifiers: KeyInput.Modifiers = [.shift],
        phase: KeyStroke.Phase = .down,
        composing: Bool = false,
        keyCode: UInt16 = 0x24
    ) -> KeyStroke {
        KeyStroke(phase: phase, keyCode: keyCode, characters: "\r", modifiers: modifiers, isComposing: composing)
    }

    private func yen(
        _ modifiers: KeyInput.Modifiers = [],
        phase: KeyStroke.Phase = .down,
        composing: Bool = false
    ) -> KeyStroke {
        KeyStroke(phase: phase, keyCode: 0x5D, characters: "¥", modifiers: modifiers, isComposing: composing)
    }

    // MARK: - Shift+Enter

    // 'Shift+Enter sends ESC+CR, the sequence agent CLIs read as insert-newline'
    @Test func shiftEnterSendsEscCR() {
        #expect(shiftEnterSequence == "\u{1b}\r")
        #expect(classifyKey(enter(), settings: enabled) == .send("\u{1b}\r"))
        // テンキーの Enter も同じ（ブラウザの `key === 'Enter'` と同じ）。
        #expect(classifyKey(enter(keyCode: 0x4C), settings: enabled) == .send("\u{1b}\r"))
    }

    // 'Shift+Enter falls back to the xterm default when the option is off'
    @Test func shiftEnterIsEncodedNormallyWhenDisabled() {
        #expect(classifyKey(enter(), settings: disabled) == .encode)
    }

    // 'plain Enter still submits'
    @Test func plainEnterIsEncoded() {
        #expect(classifyKey(enter([]), settings: enabled) == .encode)
    }

    // 'Shift+Enter is rewritten on keydown only, never on keypress or keyup'
    @Test func shiftEnterIsRewrittenOnKeyDownOnly() {
        #expect(classifyKey(enter(phase: .up), settings: enabled) == .ignore)
    }

    // 'IME conversion Enter is left to the composition, not rewritten'
    @Test func enterDuringCompositionGoesToTheInputMethod() {
        #expect(classifyKey(enter(composing: true), settings: enabled) == .inputMethod)
        #expect(classifyKey(enter([], composing: true), settings: enabled) == .inputMethod)
        #expect(classifyKey(enter(phase: .up, composing: true), settings: enabled) == .ignore)
    }

    // 'other modifiers keep their existing meaning'
    @Test func otherModifiersAreNotRewritten() {
        #expect(classifyKey(enter([.shift, .control]), settings: enabled) == .encode)
        #expect(classifyKey(enter([.shift, .option]), settings: enabled) == .encode)
        #expect(classifyKey(enter([.shift, .command]), settings: enabled) == .systemShortcut)
    }

    // 'non-Enter keys are untouched'
    @Test func nonEnterKeysAreNotRewritten() {
        let shiftA = KeyStroke(keyCode: 0x00, characters: "A", charactersIgnoringModifiers: "A", modifiers: .shift)
        #expect(classifyKey(shiftA, settings: enabled) == .interpret)
        let shiftTab = KeyStroke(keyCode: 0x30, characters: "\u{19}", modifiers: .shift)
        #expect(classifyKey(shiftTab, settings: enabled) == .encode)
    }

    // MARK: - ¥

    @Test func yenIsRewrittenToBackslash() {
        #expect(classifyKey(yen(), settings: enabled) == .send("\\"))
        // Shift は付いていてもよい。
        #expect(classifyKey(yen(.shift), settings: enabled) == .send("\\"))
        // shift_enter_newline とは関係ない。
        #expect(classifyKey(yen(), settings: disabled) == .send("\\"))
    }

    @Test func yenIsNotRewrittenWithOtherModifiersOrDuringComposition() {
        // Option+¥ は macOS が合成した文字をそのまま使う（Scenario: Modified yen）。
        #expect(classifyKey(yen(.option), settings: enabled) == .interpret)
        #expect(classifyKey(yen(.control), settings: enabled) == .encode)
        #expect(classifyKey(yen(.command), settings: enabled) == .systemShortcut)
        #expect(classifyKey(yen(composing: true), settings: enabled) == .inputMethod)
        #expect(classifyKey(yen(phase: .up), settings: enabled) == .ignore)
    }

    @Test func otherCharactersAreNotRewritten() {
        let backslash = KeyStroke(keyCode: 0x5D, characters: "\\")
        #expect(classifyKey(backslash, settings: enabled) == .interpret)
        let pipe = KeyStroke(keyCode: 0x5D, characters: "|", modifiers: .shift)
        #expect(classifyKey(pipe, settings: enabled) == .interpret)
    }

    // MARK: - それ以外の経路（design D1 の 2・5・6）

    @Test func commandCombinationsAreLeftToTheMenu() {
        let commandC = KeyStroke(keyCode: 0x08, characters: "c", modifiers: .command)
        #expect(classifyKey(commandC, settings: enabled) == .systemShortcut)
        #expect(classifyKey(KeyStroke(phase: .up, keyCode: 0x08, characters: "c", modifiers: .command), settings: enabled) == .ignore)
        // Command キーそのものも送らない（離したときは Command のフラグが消えている）。
        #expect(classifyKey(KeyStroke(phase: .up, keyCode: 0x37, characters: ""), settings: enabled) == .ignore)
    }

    @Test func controlAndNonTextKeysGoStraightToTheEncoder() {
        // Ctrl+V は 0x16 としてそのまま送る（Scenario: Agent image paste）。
        let controlV = KeyStroke(keyCode: 0x09, characters: "\u{16}", charactersIgnoringModifiers: "v", modifiers: .control)
        #expect(classifyKey(controlV, settings: enabled) == .encode)
        for characters in ["\r", "\t", "\u{7f}", "\u{1b}", "\u{F700}", "\u{F704}", "\u{03}"] {
            #expect(classifyKey(KeyStroke(keyCode: 0x24, characters: characters), settings: enabled) == .encode)
        }
        // 修飾キーそのもの（flagsChanged）。
        #expect(classifyKey(KeyStroke(keyCode: 0x38, characters: "", modifiers: .shift), settings: enabled) == .encode)
        #expect(classifyKey(KeyStroke(phase: .up, keyCode: 0x38, characters: ""), settings: enabled) == .encode)
    }

    @Test func textKeysAndDeadKeysAreInterpreted() {
        #expect(classifyKey(KeyStroke(keyCode: 0x00, characters: "a"), settings: enabled) == .interpret)
        // Option+2 → ™（Option で合成する文字）
        #expect(classifyKey(KeyStroke(keyCode: 0x13, characters: "™", charactersIgnoringModifiers: "2", modifiers: .option), settings: enabled) == .interpret)
        // Option+E（デッドキー）は characters が空。IME（input context）が合成する。
        #expect(classifyKey(KeyStroke(keyCode: 0x0E, characters: "", charactersIgnoringModifiers: "e", modifiers: .option), settings: enabled) == .interpret)
        // 離したときは、押したことを報告したキーとしてエンコーダに渡す。
        #expect(classifyKey(KeyStroke(phase: .up, keyCode: 0x00, characters: "a"), settings: enabled) == .encode)
    }
}
