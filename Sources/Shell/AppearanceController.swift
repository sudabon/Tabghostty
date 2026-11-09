import AppKit
import DaemonClient
import TerminalUI

/// 解決した配色（light / dark）。
public enum ResolvedTheme: String, Equatable, Sendable {
    case light
    case dark

    /// `color_scheme` が light / dark ならその値、system ならシステムの外観に従う（webtabinal `theme.ts` の `resolveTheme`）。
    public static func resolve(_ scheme: ColorSchemeSetting, systemIsDark: Bool) -> ResolvedTheme {
        switch scheme {
        case .light: .light
        case .dark: .dark
        case .system: systemIsDark ? .dark : .light
        }
    }

    /// 端末の配色。
    public var palette: Palette { self == .dark ? .dark : .light }
    /// サイドバーなど周りの UI の配色。
    public var chrome: ChromePalette { self == .dark ? .dark : .light }

    /// ウィンドウとシートの外観。
    @MainActor public var appearance: NSAppearance? {
        NSAppearance(named: self == .dark ? .darkAqua : .aqua)
    }
}

/// 配色の解決と、システムの外観への追従（spec: color-scheme、phase4 design D6）。
///
/// `color_scheme` が system のとき、`NSApp.effectiveAppearance` を KVO で監視し、macOS の外観を切り替えたら
/// 再起動せずに追従する。解決した配色が変わったら `onChange` で知らせる（端末のパレット、chrome、ウィンドウの外観に配る）。
/// アプリ自体の `appearance` は変えないので、`effectiveAppearance` は常にシステムの外観を表す。
@MainActor
public final class AppearanceController {
    /// `color_scheme`。
    public var scheme: ColorSchemeSetting {
        didSet { update() }
    }

    /// システムの外観が暗いか。
    public private(set) var systemIsDark: Bool
    /// 解決した配色。
    public private(set) var theme: ResolvedTheme
    /// 解決した配色が変わった。
    public var onChange: ((ResolvedTheme) -> Void)?

    private var observation: NSKeyValueObservation?

    /// - Parameter application: 外観を監視するアプリ（テストでは nil にして `systemAppearanceDidChange` で渡す）
    public init(scheme: ColorSchemeSetting, application: NSApplication? = NSApp) {
        self.scheme = scheme
        let isDark = application.map { Self.isDark($0.effectiveAppearance) } ?? false
        systemIsDark = isDark
        theme = ResolvedTheme.resolve(scheme, systemIsDark: isDark)
        observation = application?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let appearance = change.newValue else { return }
            let isDark = Self.isDark(appearance)
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.systemAppearanceDidChange(isDark: isDark) }
            } else {
                Task { @MainActor in self?.systemAppearanceDidChange(isDark: isDark) }
            }
        }
    }

    isolated deinit {
        observation?.invalidate()
    }

    /// システムの外観が変わった。
    public func systemAppearanceDidChange(isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
        update()
    }

    private func update() {
        let next = ResolvedTheme.resolve(scheme, systemIsDark: systemIsDark)
        guard next != theme else { return }
        theme = next
        onChange?(next)
    }

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
