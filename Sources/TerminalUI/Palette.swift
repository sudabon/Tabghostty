import Foundation
import TerminalCore

/// 配色（design D5）。
///
/// - fg / bg / cursor は、デーモンが OSC 10 / 11 / 12 に返す値（webtabinal `internal/osc/color.go`）と同じ。
/// - 選択色は Web 版（`web/src/theme.ts`）と同じ。
/// - ANSI 16 色は xterm.js の既定値（Tango）。256 色のキューブとグレースケールは xterm の式で求める。
public struct Palette: Equatable, Sendable {
    public var foreground: ColorRGB
    public var background: ColorRGB
    public var cursor: ColorRGB
    public var selection: ColorRGB
    /// 検索の一致の背景（今の一致は `searchCurrentMatch`）。VS Code の find match の色（下地に合成した値）。
    public var searchMatch: ColorRGB
    public var searchCurrentMatch: ColorRGB
    /// 256 色（0〜15 が ANSI 16 色）。
    public var colors: [ColorRGB]

    /// xterm.js の既定の ANSI 16 色。
    public static let ansi16: [ColorRGB] = [
        0x2e3436, 0xcc0000, 0x4e9a06, 0xc4a000, 0x3465a4, 0x75507b, 0x06989a, 0xd3d7cf,
        0x555753, 0xef2929, 0x8ae234, 0xfce94f, 0x729fcf, 0xad7fa8, 0x34e2e2, 0xeeeeec,
    ].map(ColorRGB.init(hex:))

    public static let dark = Palette(
        foreground: ColorRGB(hex: 0xcccccc),
        background: ColorRGB(hex: 0x1e1e1e),
        cursor: ColorRGB(hex: 0xffffff),
        selection: ColorRGB(hex: 0x264f78),
        searchMatch: ColorRGB(hex: 0x623314),
        searchCurrentMatch: ColorRGB(hex: 0x515c6a),
        colors: xterm256()
    )

    public static let light = Palette(
        foreground: ColorRGB(hex: 0x333333),
        background: ColorRGB(hex: 0xffffff),
        cursor: ColorRGB(hex: 0x000000),
        selection: ColorRGB(hex: 0xadd6ff),
        searchMatch: ColorRGB(hex: 0xf8c9aa),
        searchCurrentMatch: ColorRGB(hex: 0xa8ac94),
        colors: xterm256()
    )

    /// 256 色パレット。16〜231 は 6×6×6 のキューブ、232〜255 はグレースケール。
    public static func xterm256() -> [ColorRGB] {
        var colors = ansi16
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for index in 0..<216 {
            colors.append(ColorRGB(r: levels[index / 36], g: levels[(index / 6) % 6], b: levels[index % 6]))
        }
        for index in 0..<24 {
            let value = UInt8(8 + 10 * index)
            colors.append(ColorRGB(r: value, g: value, b: value))
        }
        return colors
    }

    /// `color_scheme`（light / dark / system）から決める。system なら `systemIsDark` に従う。
    /// 設定や system の変化への追従は `AppearanceController`（Shell）が行う。
    public static func resolve(colorScheme: String, systemIsDark: Bool) -> Palette {
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return systemIsDark ? .dark : .light
        }
    }

    /// Terminal に設定する既定の配色。
    public var terminalColors: TerminalColorConfiguration {
        TerminalColorConfiguration(foreground: foreground, background: background, cursor: cursor, palette: colors)
    }
}

/// 前景色と背景色のコントラストを、最低限の比率まで上げる（xterm.js の `minimumContrastRatio` と同じ考え方）。
///
/// WCAG の相対輝度で比率を求め、足りなければ前景色を 10% ずつ暗く（または明るく）する。
/// 片方向で届かなければ、もう片方向も試し、比率の高い方を使う。
public enum ContrastAdjuster {
    /// Web 版と同じ比率（WCAG AA）。
    public static let minimumRatio = 4.5

    /// WCAG の相対輝度（0〜1）。
    public static func relativeLuminance(_ color: ColorRGB) -> Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    /// コントラスト比（1〜21）。
    public static func contrastRatio(_ a: ColorRGB, _ b: ColorRGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 比率が足りなければ前景色を補正して返す。足りていればそのまま返す。
    public static func adjust(foreground: ColorRGB, background: ColorRGB, ratio: Double = minimumRatio) -> ColorRGB {
        guard contrastRatio(foreground, background) < ratio else { return foreground }
        let darker = relativeLuminance(foreground) < relativeLuminance(background)
        let first = darker ? reduceLuminance(foreground, against: background, ratio: ratio)
            : increaseLuminance(foreground, against: background, ratio: ratio)
        let firstRatio = contrastRatio(first, background)
        if firstRatio >= ratio { return first }
        let second = darker ? increaseLuminance(foreground, against: background, ratio: ratio)
            : reduceLuminance(foreground, against: background, ratio: ratio)
        return firstRatio > contrastRatio(second, background) ? first : second
    }

    private static func reduceLuminance(_ color: ColorRGB, against background: ColorRGB, ratio: Double) -> ColorRGB {
        var (r, g, b) = (Int(color.r), Int(color.g), Int(color.b))
        var current = ColorRGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
        while contrastRatio(current, background) < ratio && (r > 0 || g > 0 || b > 0) {
            r -= max(0, Int((Double(r) * 0.1).rounded(.up)))
            g -= max(0, Int((Double(g) * 0.1).rounded(.up)))
            b -= max(0, Int((Double(b) * 0.1).rounded(.up)))
            current = ColorRGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
        }
        return current
    }

    private static func increaseLuminance(_ color: ColorRGB, against background: ColorRGB, ratio: Double) -> ColorRGB {
        var (r, g, b) = (Int(color.r), Int(color.g), Int(color.b))
        var current = ColorRGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
        while contrastRatio(current, background) < ratio && (r < 255 || g < 255 || b < 255) {
            r = min(255, r + Int((Double(255 - r) * 0.1).rounded(.up)))
            g = min(255, g + Int((Double(255 - g) * 0.1).rounded(.up)))
            b = min(255, b + Int((Double(255 - b) * 0.1).rounded(.up)))
            current = ColorRGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
        }
        return current
    }
}
