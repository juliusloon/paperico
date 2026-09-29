import SwiftUI

// MARK: - Palette (mirrors frontend/src/index.css CSS variables)

/// Every token mirrors the CSS custom properties in `frontend/src/index.css`.
/// `accentSoft` = 12% accent on white (light) / 19% on #20242c (dark);
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
            accentSoft: accent.mix(with: Color(hex: "#ffffff")!, ratio: 0.12),
            accentFaint: accent.mix(with: Color(hex: "#ffffff")!, ratio: 0.05),
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
            accentSoft: accent.mix(with: Color(hex: "#20242c")!, ratio: 0.19),
            accentFaint: accent.mix(with: Color(hex: "#20242c")!, ratio: 0.08),
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
        guard let a = cgColor.components, a.count >= 3, let b = other.cgColor.components, b.count >= 3 else {
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

extension Font {
    /// Charter / Iowan Old Style serif reading face → system serif (New York).
    static func reading(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// ui-monospace code face.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Status vocabulary (single source of truth, mirrors LibraryPage STATUS_*)

enum PaperStatus: String, Hashable {
    case uploaded, parsing, parsed, normalizing, analyzing, reducing, ready, error
    case unknown

    init(raw: String) {
        self = PaperStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .uploaded: return "待解析"
        case .parsing: return "解析中"
        case .parsed: return "已解析"
        case .normalizing: return "清洗中"
        case .analyzing: return "分析中"
        case .reducing: return "归纳中"
        case .ready: return "已就绪"
        case .error: return "出错"
        case .unknown: return "未知"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Palette.defaultLight(accentHex: "#275DCE").success
        case .error: return Palette.defaultLight(accentHex: "#275DCE").danger
        case .parsing, .analyzing, .reducing, .normalizing: return Palette.defaultLight(accentHex: "#275DCE").amber
        default: return Color(hex: "#9a9a9a")!
        }
    }

    /// ReadingArea.STATUS_COPY — shown on the preparing stage.
    var processingCopy: String? {
        switch self {
        case .uploaded: return "等待开始"
        case .parsing: return "MinerU 正在恢复版面结构"
        case .parsed: return "结构解析完成"
        case .normalizing: return "正在整理文本块"
        case .analyzing: return "正在翻译并提炼段落"
        case .reducing: return "正在重建全文逻辑"
        default: return nil
        }
    }

    var isActive: Bool { self != .ready && self != .error }
}

// MARK: - Method categories (mirrors MethodsPage CATEGORY_*)

enum MethodCategory {
    static let labels: [String: String] = [
        "ML_MODEL": "机器学习模型",
        "ALGORITHM": "算法/优化方法",
        "INSTRUMENT_METHOD": "表征/检测方法",
        "DATASET_BENCHMARK": "数据集/基准",
        "METRIC": "评价指标",
        "CHEMISTRY": "反应类型/试剂",
        "SOFTWARE_TOOL": "软件/工具",
        "OTHER": "其他",
    ]

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
    static func color(_ key: String) -> Color { colors[key] ?? colors["OTHER"]! }
}

// MARK: - Shadows

extension Palette {
    /// --shadow-card
    var shadowCard: Color { dark ? Color.black.opacity(0.18) : Color(hex: "#141820")!.opacity(0.055) }
    /// --shadow-float
    var shadowFloat: Color { dark ? Color.black.opacity(0.22) : Color(hex: "#141820")!.opacity(0.07) }
    var dark: Bool { !gray0.isLight }
}

extension Color {
    var isLight: Bool {
        guard let c = cgColor.components, c.count >= 3 else { return true }
        return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) > 0.6
    }
}
