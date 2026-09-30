import SwiftUI

// MARK: - Liquid Glass 适配(macOS 26 / iOS 26+,旧系统保持原有手绘外观)

/// 当前运行时是否支持 Liquid Glass(供无法内联 #available 的场景做条件分支)。
enum LiquidGlass {
    static var isSupported: Bool {
        #if os(macOS)
        if #available(macOS 26.0, *) { return true }
        #elseif os(iOS)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
}

/// accent 染色的交互玻璃变体(仅在 #available(macOS 26, *) / iOS 26 分支内调用)。
@available(macOS 26.0, iOS 26.0, *)
func accentGlass(_ color: Color) -> Glass {
    Glass.regular.tint(color).interactive()
}

// MARK: - 宽度断点(移植 web 端的媒体查询)

/// web 端 index.css 的响应式断点;app 端按根布局实际宽度套用同一组数值,
/// 让 macOS / iPad 缩窗时获得与 web 相同的比例适配。
enum LayoutBreakpoint {
    /// 阅读器三栏 → 分页栏(web @media max-width 900px)。
    static let reader: CGFloat = 900
    /// 设置页双栏 → 单栏 + 横向 tab(web @media max-width 800px)。
    static let settings: CGFloat = 800
    /// 工作台页侧栏 → 抽屉 + 顶部导航条(web @media max-width 760px)。
    static let workspace: CGFloat = 760
    /// 首页 hero/下栏切换单列(web @media max-width 860px)。
    static let hero: CGFloat = 860
    /// 首页小屏排版(web @media max-width 640px)。
    static let home: CGFloat = 640
}

private struct ContainerWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1280
}

extension EnvironmentValues {
    /// 根布局实际宽度(RootView 注入),替代 horizontalSizeClass 做窄窗适配。
    var containerWidth: CGFloat {
        get { self[ContainerWidthKey.self] }
        set { self[ContainerWidthKey.self] = newValue }
    }
}

// MARK: - 玻璃面板(页面级 panel 统一为液态玻璃圆角矩形)

/// 页面 panel 的统一表面:macOS/iOS 26+ 用 Liquid Glass,旧系统回退到手绘卡片。
/// 圆角由调用方保持原值(侧栏/主栏 14,卡片 12,首页指标条 12)。
private struct LiquidPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            legacy(content)
        }
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(palette.gray0))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(palette.gray300.opacity(0.68)))
            .shadow(color: palette.shadowCard, radius: 8, y: 3)
    }
}

/// 浮动小件(阅读器悬浮工具)的统一表面:交互玻璃 + accent 按压染色。
struct LiquidToolModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color? = nil
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            legacy(content)
        }
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    @available(macOS 26.0, iOS 26.0, *)
    private var glass: Glass {
        if let tint { return accentGlass(tint) }
        return .regular.interactive()
    }

    private func legacy(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(tint ?? palette.gray0.opacity(0.92))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).stroke(tint ?? palette.gray300.opacity(0.72)))
            .shadow(color: palette.shadowFloat, radius: 10, y: 4)
    }
}

extension View {
    /// 页面级 panel:侧栏、主内容卡、首页面板、阅读器右侧卡等。
    func liquidPanel(cornerRadius: CGFloat = 14) -> some View {
        modifier(LiquidPanelModifier(cornerRadius: cornerRadius))
    }

    /// 浮动工具小件(阅读器悬浮工具条上的单件)。
    func liquidTool(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(LiquidToolModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - 聚焦框(蓝色方框)禁用

extension View {
    /// macOS 的 popover 初始焦点与全键盘导航会给自绘按钮套系统蓝色聚焦框,
    /// 自绘的导航/工具按钮统一禁用;输入框、拾色器等系统控件不受影响。
    @ViewBuilder
    func noFocusRing() -> some View {
        #if os(macOS)
        self.focusable(false)
        #else
        self
        #endif
    }
}

// MARK: - macOS 红绿灯留白

extension View {
    /// 隐藏标题栏后红绿灯悬浮在窗口左上角;给面板/内容顶部留出安全高度。
    /// 非 macOS 平台为无操作。
    ///
    /// 高度不再硬编码 34pt,而是取 `WindowChrome.additionalTopClearance`
    /// (见 App/WindowChrome.swift):它已经扣掉系统自动保留的顶部安全区,
    /// 避免在 macOS 26+ 上形成 32 + 34 = 66pt 的突兀空档。
    func trafficLightTopPadding(_ extra: CGFloat = 0) -> some View {
        modifier(TrafficLightTopPaddingModifier(extra: extra))
    }
}

private struct TrafficLightTopPaddingModifier: ViewModifier {
    var extra: CGFloat
    @Environment(\.trafficLightClearance) private var clearance

    func body(content: Content) -> some View {
        #if os(macOS)
        content.padding(.top, clearance + extra)
        #else
        content
        #endif
    }
}
