import SwiftUI

// MARK: - Palette (design tokens shared with the web client's index.css)

/// Every token mirrors the CSS custom properties originally defined in the
/// web client's `index.css` (web client is local-only now, but keep names in sync).
/// Translucent accent layers: 12% (light) / 19% (dark);
/// `accentFaint` = 5% / 8%.
struct Palette {
    var accent: Color
    var accentSoft: Color
    var accentFaint: Color
    var appBase: Color
    var amber: Color
    var success: Color
    var danger: Color
    var gray0: Color   // surface (cards)
    var gray50: Color
    var gray100: Color
    var gray200: Color
    var gray300: Color
    var gray400: Color
    var gray500: Color
    var gray600: Color
    var gray700: Color
    var gray800: Color
    var gray900: Color

    static func defaultLight(accentHex: String) -> Palette {
        let accent = Color(hex: accentHex) ?? Color(hex: "#275DCE")!
        return Palette(
            accent: accent,
            accentSoft: accent.opacity(0.12),
            accentFaint: accent.opacity(0.05),
            appBase: Color(hex: "#ffffff")!,
            amber: Color(hex: "#B66A12")!,
            success: Color(hex: "#237A52")!,
            danger: Color(hex: "#B64235")!,
            gray0: Color(hex: "#ffffff")!,
            gray50: Color(hex: "#f7f8fa")!,
            gray100: Color(hex: "#eef0f3")!,
            gray200: Color(hex: "#dfe2e7")!,
            gray300: Color(hex: "#c7cbd2")!,
            gray400: Color(hex: "#989da7")!,
            gray500: Color(hex: "#6e747f")!,
            gray600: Color(hex: "#515762")!,
            gray700: Color(hex: "#343943")!,
            gray800: Color(hex: "#20242b")!,
            gray900: Color(hex: "#111419")!
        )
    }

    static func defaultDark(accentHex: String) -> Palette {
        let userAccent = Color(hex: accentHex) ?? Color(hex: "#2F6FED")!
        let accent = userAccent.mix(with: Color(hex: "#f4f6fa")!, ratio: 0.82)
        return Palette(
            accent: accent,
            accentSoft: accent.opacity(0.19),
            accentFaint: accent.opacity(0.08),
            appBase: Color(hex: "#171a20")!,
            amber: Color(hex: "#e0a45b")!,
            success: Color(hex: "#65b98d")!,
            danger: Color(hex: "#e37d73")!,
            gray0: Color(hex: "#20242c")!,
            gray50: Color(hex: "#252a33")!,
            gray100: Color(hex: "#2b303a")!,
            gray200: Color(hex: "#373e49")!,
            gray300: Color(hex: "#48515f")!,
            gray400: Color(hex: "#778290")!,
            gray500: Color(hex: "#98a2af")!,
            gray600: Color(hex: "#b6bec9")!,
            gray700: Color(hex: "#d0d6de")!,
            gray800: Color(hex: "#e4e8ed")!,
            gray900: Color(hex: "#f3f5f7")!
        )
    }

    static func `default`(accentHex: String, dark: Bool) -> Palette {
        dark ? .defaultDark(accentHex: accentHex) : .defaultLight(accentHex: accentHex)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.defaultLight(accentHex: "#275DCE")
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Color helpers

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            opacity: 1
        )
    }

    /// `ratio` = share of `self` in the blend (0 → other, 1 → self).
    func mix(with other: Color, ratio: Double) -> Color {
        let t = max(0, min(1, ratio))
        guard let a = rgbComponents, a.count >= 3, let b = other.rgbComponents, b.count >= 3 else {
            return self
        }
        return Color(
            red: (a[0] * t) + (b[0] * (1 - t)),
            green: (a[1] * t) + (b[1] * (1 - t)),
            blue: (a[2] * t) + (b[2] * (1 - t)),
            opacity: 1
        )
    }

    /// Backend chips use `catColor + '20'` (hex alpha 0x20/0xFF ≈ 12.5%).
    func chipBackground() -> Color { self.opacity(0.125) }
}

// MARK: - Typography

// MARK: - Status vocabulary (single source of truth, mirrors LibraryPage STATUS_*)

// MARK: - Method categories (mirrors MethodsPage CATEGORY_*)

enum MethodCategory {
    static let labels = Dictionary(uniqueKeysWithValues: MethodGroup.presets.map { ($0.id, $0.name) })

    static let colors: [String: Color] = [
        "ML_MODEL": Color(hex: "#2563eb")!,
        "ALGORITHM": Color(hex: "#7c3aed")!,
        "INSTRUMENT_METHOD": Color(hex: "#0891b2")!,
        "DATASET_BENCHMARK": Color(hex: "#059669")!,
        "METRIC": Color(hex: "#d97706")!,
        "CHEMISTRY": Color(hex: "#dc2626")!,
        "SOFTWARE_TOOL": Color(hex: "#4f46e5")!,
        "OTHER": Color(hex: "#6b7280")!,
    ]

    static func label(_ key: String) -> String { labels[key] ?? key }

    /// 深色底上保持色相、混入约 65% 亮色提亮(设计规范:中性色阶反转,
    /// 强调色按需调明度保证对比度);浅色底用原值。
    static func color(_ key: String, dark: Bool = false) -> Color {
        let base = colors[key] ?? colors["OTHER"]!
        return dark ? base.mix(with: Color(hex: "#f4f6fa")!, ratio: 0.35) : base
    }
}

// MARK: - Shadows

extension Palette {
    /// Use the ink with the higher WCAG contrast against the actual accent.
    var accentForeground: Color { accent.contrastingForeground }

    /// Nested content needs only a subtle tonal layer over the glass panel.
    var insetSurface: Color { dark ? Color.white.opacity(0.045) : Color.black.opacity(0.025) }

    /// --shadow-card
    var shadowCard: Color { dark ? Color.black.opacity(0.18) : Color(hex: "#141820")!.opacity(0.055) }
    /// --shadow-float
    var shadowFloat: Color { dark ? Color.black.opacity(0.22) : Color(hex: "#141820")!.opacity(0.07) }
    var dark: Bool { !gray0.isLight }
}

extension Color {
    /// `Color.cgColor` 在 macOS 上是 `CGColor?`(iOS 为非 optional),统一为可空访问。
    var rgbComponents: [CGFloat]? {
        #if os(macOS)
        let color = cgColor
        #else
        let color: CGColor? = cgColor
        #endif
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return color.converted(to: space, intent: .relativeColorimetric, options: nil)?.components
    }

    /// WCAG 2 relative luminance: linearize sRGB before weighting channels.
    var relativeLuminance: Double {
        guard let components = rgbComponents, components.count >= 3 else { return 1 }
        let linear = components.prefix(3).map { channel -> Double in
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    /// Prefer white ink on saturated control fills; use black when the fill is
    /// too light for 3:1 white contrast. Body text uses the semantic palette.
    var contrastingForeground: Color {
        let luminance = relativeLuminance
        let whiteContrast = 1.05 / (luminance + 0.05)
        return whiteContrast >= 3 ? .white : .black
    }

    var isLight: Bool {
        guard let c = rgbComponents, c.count >= 3 else { return true }
        return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) > 0.6
    }
}
