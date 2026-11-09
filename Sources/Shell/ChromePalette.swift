import AppKit
import TerminalCore

/// アプリの外枠（サイドバー、メニュー、シート）の色 1 つ。
public struct ChromeColor: Equatable, Sendable {
    public var rgb: ColorRGB
    public var alpha: Double

    public init(hex: UInt32, alpha: Double = 1) {
        rgb = ColorRGB(hex: hex)
        self.alpha = alpha
    }

    public init(rgb: ColorRGB, alpha: Double = 1) {
        self.rgb = rgb
        self.alpha = alpha
    }

    /// 透明度だけを変えた色（Web 版の `color-mix(in srgb, <color> N%, transparent)`）。
    public func withAlpha(_ alpha: Double) -> ChromeColor {
        ChromeColor(rgb: rgb, alpha: alpha)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: alpha)
    }

    public var cgColor: CGColor { nsColor.cgColor }
}

/// Web 版の chrome トークン（webtabinal `web/src/index.css` の `:root` と `[data-theme="light"]`）。
///
/// 配色を切り替えると、`AppearanceController` が解決した配色の値に差し替える（phase4 design D6）。
public struct ChromePalette: Equatable, Sendable {
    public var background: ChromeColor
    public var sidebar: ChromeColor
    public var border: ChromeColor
    public var text: ChromeColor
    public var muted: ChromeColor
    public var accent: ChromeColor
    public var danger: ChromeColor
    /// アクティブなタブの背景。
    public var active: ChromeColor
    public var hover: ChromeColor
    public var dangerBackground: ChromeColor
    public var dangerText: ChromeColor
    public var overlay: ChromeColor
    public var shadow: ChromeColor

    public static let dark = ChromePalette(
        background: ChromeColor(hex: 0x1e1e1e),
        sidebar: ChromeColor(hex: 0x252526),
        border: ChromeColor(hex: 0x3c3c3c),
        text: ChromeColor(hex: 0xcccccc),
        muted: ChromeColor(hex: 0x8a8a8a),
        accent: ChromeColor(hex: 0x89d185),
        danger: ChromeColor(hex: 0xf14c4c),
        active: ChromeColor(hex: 0x2a2d2e),
        hover: ChromeColor(hex: 0x2c2c2c),
        dangerBackground: ChromeColor(hex: 0x3a1d1d),
        dangerText: ChromeColor(hex: 0xffb4b4),
        overlay: ChromeColor(hex: 0x000000, alpha: 0.55),
        shadow: ChromeColor(hex: 0x000000, alpha: 0.35)
    )

    public static let light = ChromePalette(
        background: ChromeColor(hex: 0xffffff),
        sidebar: ChromeColor(hex: 0xf3f3f3),
        border: ChromeColor(hex: 0xd4d4d4),
        text: ChromeColor(hex: 0x333333),
        muted: ChromeColor(hex: 0x6e6e6e),
        accent: ChromeColor(hex: 0x388a34),
        danger: ChromeColor(hex: 0xcd3131),
        active: ChromeColor(hex: 0xe4e6f1),
        hover: ChromeColor(hex: 0xe8e8e8),
        dangerBackground: ChromeColor(hex: 0xfdecec),
        dangerText: ChromeColor(hex: 0x8a1f1f),
        overlay: ChromeColor(hex: 0x000000, alpha: 0.35),
        shadow: ChromeColor(hex: 0x000000, alpha: 0.18)
    )

    /// `color_scheme`（light / dark / system）から決める。system なら `systemIsDark` に従う。
    public static func resolve(colorScheme: String, systemIsDark: Bool) -> ChromePalette {
        switch colorScheme {
        case "light": return .light
        case "dark": return .dark
        default: return systemIsDark ? .dark : .light
        }
    }

    /// この配色が暗いか（シートやメニューの外観を合わせるのに使う）。
    public var isDark: Bool { self == .dark }

    /// 配色に合う `NSAppearance`。
    @MainActor public var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}
