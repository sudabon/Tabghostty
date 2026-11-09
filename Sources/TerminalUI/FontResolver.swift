import AppKit
import CoreText

/// `font_family`（CSS 風のカンマ区切り）と `font_size` からフォントを決める（design D5、spec: terminal-rendering）。
///
/// - 各要素の前後の空白と引用符を取り除き、先頭から順にインストール済みのものを探す。
/// - `monospace` はシステムの等幅フォントにする。
/// - 太字と斜体は、選んだファミリーの trait を使う。
/// - フォントに無い文字（CJK、絵文字、記号）は、フォールバックフォントで描く（結果はキャッシュする）。
public final class FontResolver {
    /// 見つからなかったときに使う、CSS の総称ファミリー。
    public static let genericMonospace = "monospace"

    public let size: CGFloat
    /// 選ばれたファミリー名（`monospace` ならシステムの等幅フォント）。
    public let familyName: String
    public let regular: NSFont
    public let bold: NSFont
    public let italic: NSFont
    public let boldItalic: NSFont

    private var fallbackCache: [FallbackKey: CTFont] = [:]

    private struct FallbackKey: Hashable {
        let text: String
        let bold: Bool
        let italic: Bool
    }

    public init(fontFamily: String, size: CGFloat) {
        self.size = size
        let resolved = Self.resolve(fontFamily: fontFamily, size: size)
        familyName = resolved.family
        regular = resolved.font
        if resolved.family == Self.genericMonospace {
            bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
            italic = Self.convert(regular, trait: .italicFontMask)
            boldItalic = Self.convert(bold, trait: .italicFontMask)
        } else {
            bold = Self.convert(regular, trait: .boldFontMask)
            italic = Self.convert(regular, trait: .italicFontMask)
            boldItalic = Self.convert(bold, trait: .italicFontMask)
        }
    }

    /// CSS の `font-family` の値を要素に分ける（前後の空白と引用符を取り除く）。
    public static func parseFamilyList(_ value: String) -> [String] {
        value.split(separator: ",").compactMap { part in
            var name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count >= 2, let first = name.first, let last = name.last,
               (first == "'" && last == "'") || (first == "\"" && last == "\"") {
                name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            return name.isEmpty ? nil : name
        }
    }

    /// 最初にインストールされているファミリーのフォントを返す。どれも無ければシステムの等幅フォント。
    public static func resolve(fontFamily: String, size: CGFloat) -> (family: String, font: NSFont) {
        let installed = NSFontManager.shared.availableFontFamilies
        for name in parseFamilyList(fontFamily) {
            if name.caseInsensitiveCompare(genericMonospace) == .orderedSame
                || name.caseInsensitiveCompare("ui-monospace") == .orderedSame {
                return (genericMonospace, NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
            }
            guard let family = installed.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
                  let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) else {
                continue
            }
            return (family, font)
        }
        return (genericMonospace, NSFont.monospacedSystemFont(ofSize: size, weight: .regular))
    }

    /// 太字・斜体のフォント。
    public func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
        switch (isBold, isItalic) {
        case (false, false): return regular
        case (true, false): return bold
        case (false, true): return italic
        case (true, true): return boldItalic
        }
    }

    /// `text` を描けるフォント。基本のフォントで描けなければ、システムのフォールバックを探す。
    public func fontForText(_ text: String, bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        let base = font(bold: isBold, italic: isItalic) as CTFont
        // ASCII は等幅フォントにあるとみなす（描画のたびに調べない）。
        guard !text.isEmpty, !text.utf8.allSatisfy({ $0 < 0x80 }) else { return base }
        let key = FallbackKey(text: text, bold: isBold, italic: isItalic)
        if let cached = fallbackCache[key] { return cached }
        let resolved = Self.canRender(text, with: base)
            ? base
            : CTFontCreateForString(base, text as CFString, CFRange(location: 0, length: (text as NSString).length))
        fallbackCache[key] = resolved
        return resolved
    }

    /// フォントが `text` の文字すべてにグリフを持つか。
    /// 結合子（ZWJ）と異体字セレクタは単独のグリフを持たないので数えない（字形の合成はシェーピングで行われる）。
    static func canRender(_ text: String, with font: CTFont) -> Bool {
        let scalars = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200D, 0xFE00...0xFE0F, 0xE0100...0xE01EF: return false
            default: return true
            }
        }
        let utf16 = Array(String(String.UnicodeScalarView(scalars)).utf16)
        guard !utf16.isEmpty else { return true }
        // サロゲートペアでは 2 つ目の要素に 0 が入るので、グリフの値ではなく戻り値（全部の文字があるか）で判断する。
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        return CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count)
    }

    private static func convert(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: trait)
    }
}
