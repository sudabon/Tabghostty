import AppKit
import Testing
import TerminalCore
@testable import TerminalUI

/// spec: terminal-rendering「Font resolution from the configured font stack」「Cell drawing」。
@Suite struct FontResolverTests {
    @Test func familyListIsTrimmedAndUnquoted() {
        #expect(FontResolver.parseFamilyList("Menlo, Monaco, 'Courier New', monospace") == ["Menlo", "Monaco", "Courier New", "monospace"])
        #expect(FontResolver.parseFamilyList(#"  "JetBrains Mono" ,, monospace "#) == ["JetBrains Mono", "monospace"])
        #expect(FontResolver.parseFamilyList("") == [])
    }

    // Scenario: First installed family wins
    @Test func firstInstalledFamilyWins() {
        let fonts = FontResolver(fontFamily: "NoSuchFont, Menlo, monospace", size: 14)
        #expect(fonts.familyName == "Menlo")
        #expect(fonts.regular.familyName == "Menlo")
        #expect(fonts.regular.pointSize == 14)
    }

    @Test func quotedFamilyIsFound() {
        let fonts = FontResolver(fontFamily: "'Courier New', monospace", size: 13)
        #expect(fonts.familyName == "Courier New")
    }

    // Scenario: Generic monospace
    @Test func genericMonospaceIsTheSystemMonospacedFont() {
        let fonts = FontResolver(fontFamily: "monospace", size: 14)
        #expect(fonts.familyName == FontResolver.genericMonospace)
        #expect(fonts.regular.fontName == NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName)
        // 何も見つからなければ、同じくシステムの等幅フォント。
        #expect(FontResolver(fontFamily: "NoSuchFont", size: 14).regular.fontName == fonts.regular.fontName)
    }

    @Test func boldAndItalicUseTheFamilyTraits() {
        let fonts = FontResolver(fontFamily: "Menlo", size: 14)
        let manager = NSFontManager.shared
        #expect(manager.traits(of: fonts.bold).contains(.boldFontMask))
        #expect(manager.traits(of: fonts.italic).contains(.italicFontMask))
        #expect(manager.traits(of: fonts.boldItalic).contains([.boldFontMask, .italicFontMask]))
        #expect(fonts.bold.familyName == "Menlo")
    }

    // Scenario: Fallback glyphs
    @Test func missingGlyphsUseAFallbackFont() {
        let fonts = FontResolver(fontFamily: "Menlo", size: 14)
        let ascii = fonts.fontForText("a", bold: false, italic: false)
        #expect(CTFontCopyFamilyName(ascii) as String == "Menlo")

        for text in ["日", "本", "語", "👨‍👩‍👧"] {
            let font = fonts.fontForText(text, bold: false, italic: false)
            #expect(CTFontCopyFamilyName(font) as String != "Menlo", "\(text)")
            #expect(FontResolver.canRender(text, with: font), "\(text)")
            // 2 回目はキャッシュから返る。
            #expect(fonts.fontForText(text, bold: false, italic: false) == font)
        }
    }
}

@Suite struct PaletteTests {
    // Scenario: Default colors match the daemon（internal/osc/color.go と web/src/theme.ts）
    @Test func defaultColorsMatchTheDaemonAndWebClient() {
        #expect(Palette.dark.foreground == ColorRGB(hex: 0xcccccc))
        #expect(Palette.dark.background == ColorRGB(hex: 0x1e1e1e))
        #expect(Palette.dark.cursor == ColorRGB(hex: 0xffffff))
        #expect(Palette.dark.selection == ColorRGB(hex: 0x264f78))
        #expect(Palette.light.foreground == ColorRGB(hex: 0x333333))
        #expect(Palette.light.background == ColorRGB(hex: 0xffffff))
        #expect(Palette.light.cursor == ColorRGB(hex: 0x000000))
        #expect(Palette.light.selection == ColorRGB(hex: 0xadd6ff))
    }

    @Test func ansi16MatchesXtermJSDefaults() {
        let expected: [UInt32] = [
            0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
            0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec,
        ]
        #expect(Array(Palette.dark.colors.prefix(16)) == expected.map(ColorRGB.init(hex:)))
        #expect(Array(Palette.light.colors.prefix(16)) == expected.map(ColorRGB.init(hex:)))
    }

    @Test func colorCubeAndGrayscaleFollowXterm() {
        let colors = Palette.xterm256()
        #expect(colors.count == 256)
        #expect(colors[16] == ColorRGB(hex: 0x000000))
        #expect(colors[21] == ColorRGB(hex: 0x0000ff))
        #expect(colors[196] == ColorRGB(hex: 0xff0000))
        #expect(colors[67] == ColorRGB(hex: 0x5f87af))
        #expect(colors[231] == ColorRGB(hex: 0xffffff))
        #expect(colors[232] == ColorRGB(hex: 0x080808))
        #expect(colors[255] == ColorRGB(hex: 0xeeeeee))
    }

    @Test func schemeResolution() {
        #expect(Palette.resolve(colorScheme: "light", systemIsDark: true) == .light)
        #expect(Palette.resolve(colorScheme: "dark", systemIsDark: false) == .dark)
        #expect(Palette.resolve(colorScheme: "system", systemIsDark: true) == .dark)
        #expect(Palette.resolve(colorScheme: "system", systemIsDark: false) == .light)
    }

    // パレットを設定した Terminal は、ANSI 色を同じ値に解決する（SGR 31 → #cc0000）。
    @Test func terminalResolvesPaletteColors() throws {
        let terminal = try VTTerminal(cols: 20, rows: 2, maxScrollback: 10)
        try terminal.setColors(Palette.dark.terminalColors)
        terminal.write(Array("\u{1b}[31mR\u{1b}[38;5;67mC\u{1b}[38;2;10;20;30mT".utf8))
        let snapshot = try terminal.makeSnapshot(forceFull: true)
        let cells = snapshot.dirtyRows.first { $0.y == 0 }?.cells ?? []
        #expect(cells[0].foreground == ColorRGB(hex: 0xcc0000))
        #expect(cells[0].foregroundPaletteIndex == 1)
        #expect(cells[1].foreground == ColorRGB(hex: 0x5f87af))
        #expect(cells[2].foreground == ColorRGB(r: 10, g: 20, b: 30))
        #expect(snapshot.colors.background == ColorRGB(hex: 0x1e1e1e))
        #expect(snapshot.colors.foreground == ColorRGB(hex: 0xcccccc))
    }
}

/// spec: terminal-rendering「Cell drawing」— Scenario: Low-contrast foreground。
@Suite struct ContrastAdjusterTests {
    @Test func knownRatios() {
        #expect(abs(ContrastAdjuster.contrastRatio(ColorRGB(hex: 0x000000), ColorRGB(hex: 0xffffff)) - 21) < 0.01)
        #expect(abs(ContrastAdjuster.contrastRatio(ColorRGB(hex: 0x777777), ColorRGB(hex: 0xffffff)) - 4.48) < 0.01)
    }

    @Test func sufficientContrastIsUnchanged() {
        let fg = Palette.dark.foreground
        #expect(ContrastAdjuster.adjust(foreground: fg, background: Palette.dark.background) == fg)
    }

    @Test func lowContrastIsRaisedToTheMinimum() {
        let samples: [UInt32] = [
            0x000000, 0x1e1e1e, 0x2e3436, 0x333333, 0x555753, 0x777777, 0x808080, 0x8ae234,
            0xc4a000, 0xcccccc, 0xd3d7cf, 0xeeeeec, 0xfce94f, 0xff0000, 0x0000ff, 0xffffff,
        ]
        for background in samples.map(ColorRGB.init(hex:)) {
            for foreground in samples.map(ColorRGB.init(hex:)) {
                let adjusted = ContrastAdjuster.adjust(foreground: foreground, background: background)
                let ratio = ContrastAdjuster.contrastRatio(adjusted, background)
                #expect(ratio >= 4.5, "fg \(foreground) on bg \(background) → \(adjusted) ratio \(ratio)")
            }
        }
    }

    // ライトテーマで、既定の（暗い）前景色を黒い背景に描くと明るくする（web/src/theme.ts の注記の例）。
    @Test func darkTextOnBlackCellIsLightened() {
        let adjusted = ContrastAdjuster.adjust(foreground: Palette.light.foreground, background: ColorRGB(hex: 0x000000))
        #expect(ContrastAdjuster.relativeLuminance(adjusted) > ContrastAdjuster.relativeLuminance(Palette.light.foreground))
    }
}
