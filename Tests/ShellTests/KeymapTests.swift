import DaemonClient
import Testing
import TerminalCore
@testable import Shell

/// webtabinal `web/tests/keymap.test.ts` の 7 件の移植（spec: keyboard-shortcuts「Key binding notation and validation」）。
///
/// Web 版は `KeyboardEvent`（`key` と修飾キー）を正規化する。ネイティブ版は `NSEvent` の値（`KeyStroke`）を正規化するので、
/// 同じキーを `KeyStroke` で表して確かめる。
@Suite struct KeymapTests {
    private let enabled = KeyBindings(enabled: true)

    private func stroke(
        _ characters: String,
        keyCode: UInt16,
        ignoring: String? = nil,
        modifiers: KeyInput.Modifiers = [],
        composing: Bool = false
    ) -> KeyStroke {
        KeyStroke(keyCode: keyCode, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                  modifiers: modifiers, isComposing: composing)
    }

    // normalizeKeyEvent uses a fixed modifier order and lowercases the base key
    @Test func normalizeUsesAFixedModifierOrderAndLowercasesTheBaseKey() {
        // Control+Shift+P（Shift が反映された文字は `P`）。
        #expect(Keymap.normalize(stroke("\u{10}", keyCode: 0x23, ignoring: "P", modifiers: [.shift, .control])) == "ctrl+shift+p")
        // Scenario: Normalization order（Control+Shift+K）
        #expect(Keymap.normalize(stroke("\u{0b}", keyCode: 0x28, ignoring: "K", modifiers: [.control, .shift])) == "ctrl+shift+k")
        #expect(Keymap.normalize(stroke(
            "\u{F701}", keyCode: 0x7D, modifiers: [.command, .shift, .option, .control]
        )) == "ctrl+alt+shift+meta+arrowdown")
        #expect(Keymap.normalize(stroke("n", keyCode: 0x2D)) == "n")
        #expect(Keymap.normalize(stroke(" ", keyCode: 0x31)) == "space")
        #expect(Keymap.normalize(stroke("\u{1b}", keyCode: 0x35)) == "escape")
        #expect(Keymap.normalize(stroke("\n", keyCode: 0x26, ignoring: "j", modifiers: .control)) == "ctrl+j")
    }

    // normalizeKeyEvent returns null for modifier-only keys and IME composition
    @Test func normalizeReturnsNilForModifierOnlyKeysAndComposition() {
        #expect(Keymap.normalize(stroke("", keyCode: 0x3B, modifiers: .control)) == nil)
        #expect(Keymap.normalize(stroke("", keyCode: 0x37, modifiers: .command)) == nil)
        #expect(Keymap.normalize(stroke("\n", keyCode: 0x26, ignoring: "j", modifiers: .control, composing: true)) == nil)
        // 文字を作らないデッドキー。
        #expect(Keymap.normalize(stroke("", keyCode: 0x20, ignoring: "", modifiers: .option)) == nil)
    }

    // formatBinding renders a readable chord
    @Test func formatRendersAReadableChord() {
        #expect(Keymap.format("ctrl+j") == "Ctrl+J")
        #expect(Keymap.format("n") == "N")
        #expect(Keymap.format("p") == "P")
        #expect(Keymap.format("meta+n") == "Cmd+N")
        #expect(Keymap.format("ctrl+shift+arrowdown") == "Ctrl+Shift+Arrowdown")
        #expect(Keymap.format("") == "")
    }

    // validateBindings accepts the default chord
    @Test func validateAcceptsTheDefaultChord() {
        #expect(Keymap.validate(KeyBindings.default) == nil)
        #expect(Keymap.validate(enabled) == nil)
    }

    // validateBindings rejects each invalid case
    @Test func validateRejectsEachInvalidCase() {
        func with(_ change: (inout KeyBindings) -> Void) -> KeyBindings {
            var bindings = enabled
            change(&bindings)
            return bindings
        }
        #expect(Keymap.validate(with { $0.prefix = "j" }) == .prefixNoModifier)
        #expect(Keymap.validate(with { $0.nextTab = "n"; $0.prevTab = "n" }) == .duplicateActionKey)
        #expect(Keymap.validate(with { $0.toggleSidebar = "n" }) == .duplicateActionKey)
        #expect(Keymap.validate(with { $0.toggleSidebar = "p" }) == .duplicateActionKey)
        #expect(Keymap.validate(with { $0.prefix = "escape" }) == .escape)
        #expect(Keymap.validate(with { $0.nextTab = "escape" }) == .escape)
        #expect(Keymap.validate(with { $0.toggleSidebar = "escape" }) == .escape)
        #expect(Keymap.validate(with { $0.prefix = "Ctrl+J" }) == .unparsable)
        #expect(Keymap.validate(with { $0.prefix = "" }) == .unparsable)
        #expect(Keymap.validate(with { $0.toggleSidebar = "" }) == .unparsable)
        #expect(Keymap.validate(with { $0.prefix = "shift+ctrl+j" }) == .unparsable)
        // Scenario: Reserved prefix
        #expect(Keymap.validate(with { $0.prefix = "meta+n" }) == .reserved)
        #expect(Keymap.validate(with { $0.prefix = "meta+1" }) == .reserved)
        #expect(Keymap.validate(with { $0.prefix = "meta+c" }) == .reserved)
        #expect(Keymap.validate(with { $0.prefix = "meta+v" }) == .reserved)
    }

    // resolveChordKey implements the prefix state machine
    @Test func resolveImplementsThePrefixStateMachine() {
        func resolve(_ pending: Bool, _ spec: String?, _ bindings: KeyBindings) -> ChordResolution {
            Keymap.resolve(pending: pending, spec: spec, bindings: bindings)
        }
        #expect(resolve(false, "ctrl+j", enabled) == ChordResolution(pending: true, action: .arm))
        #expect(resolve(true, "n", enabled) == ChordResolution(pending: false, action: .next))
        #expect(resolve(true, "p", enabled) == ChordResolution(pending: false, action: .prev))
        #expect(resolve(true, "j", enabled) == ChordResolution(pending: false, action: .toggleSidebar))
        #expect(resolve(true, "x", enabled) == ChordResolution(pending: false, action: .cancel))
        #expect(resolve(true, "escape", enabled) == ChordResolution(pending: false, action: .cancel))
        #expect(resolve(true, "ctrl+j", enabled) == ChordResolution(pending: true, action: .arm))
        #expect(resolve(false, "n", enabled) == ChordResolution(pending: false, action: .none))
        #expect(resolve(true, nil, enabled) == ChordResolution(pending: true, action: .none))
        #expect(resolve(false, "ctrl+j", .default) == ChordResolution(pending: false, action: .none))
        #expect(resolve(true, "j", .default) == ChordResolution(pending: false, action: .none))
    }

    // neighbourTabIndex wraps and no-ops for a single or missing session
    @Test func neighbourTabIndexWrapsAndNoOpsForASingleOrMissingSession() {
        #expect(Keymap.neighbourTabIndex(count: 3, activeIndex: 2, direction: .next) == 0)
        #expect(Keymap.neighbourTabIndex(count: 3, activeIndex: 0, direction: .prev) == 2)
        #expect(Keymap.neighbourTabIndex(count: 3, activeIndex: 1, direction: .next) == 2)
        #expect(Keymap.neighbourTabIndex(count: 1, activeIndex: 0, direction: .next) == 0)
        #expect(Keymap.neighbourTabIndex(count: 1, activeIndex: 0, direction: .prev) == 0)
        #expect(Keymap.neighbourTabIndex(count: 0, activeIndex: 0, direction: .next) == -1)
        #expect(Keymap.neighbourTabIndex(count: 3, activeIndex: -1, direction: .next) == -1)
    }
}
