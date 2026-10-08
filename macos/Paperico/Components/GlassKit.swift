import SwiftUI

/// Continuous corners keep nested surfaces visually related; icon controls use circles.
enum CornerRadius {
    static let card: CGFloat = 20
    static let inset: CGFloat = 12
    static let chip: CGFloat = 8
}

private struct BackgroundOpacityKey: EnvironmentKey { static let defaultValue: Double = 1 }
private struct GlassOpacityKey: EnvironmentKey { static let defaultValue: Double = 0.85 }
private struct FloatingSurfaceKey: EnvironmentKey { static let defaultValue = false }
private struct DrawerSurfaceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var backgroundOpacity: Double {
        get { self[BackgroundOpacityKey.self] }
        set { self[BackgroundOpacityKey.self] = newValue }
    }
    var glassOpacity: Double {
        get { self[GlassOpacityKey.self] }
        set { self[GlassOpacityKey.self] = newValue }
    }
    var floatingSurface: Bool {
        get { self[FloatingSurfaceKey.self] }
        set { self[FloatingSurfaceKey.self] = newValue }
    }
    var drawerSurface: Bool {
        get { self[DrawerSurfaceKey.self] }
        set { self[DrawerSurfaceKey.self] = newValue }
    }
}

// MARK: - 桌面侧栏轨道的宽度断点

/// 根布局实际宽度决定侧栏是否收起，页面内容一直保留桌面布局。
enum LayoutBreakpoint {
    /// 阅读器页边逻辑链自动让位给正文的宽度。
    static let reader: CGFloat = 900
    /// 设置侧栏自动收成图标轨道。
    static let settings: CGFloat = 800
    /// 工作台侧栏自动收成桌面的窄轨道。
    static let workspace: CGFloat = 760
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

/// Fade only the material, never its foreground. Regular glass keeps light
/// surfaces visible; the independent opacity preference permits full build tuning.
struct GlassSurface<S: Shape>: View {
    let shape: S
    var tint: Color? = nil
    var interactive = false
    var bordered = true
    @Environment(\.palette) private var palette
    @Environment(\.glassOpacity) private var glassOpacity
    @Environment(\.floatingSurface) private var floatingSurface
    @Environment(\.drawerSurface) private var drawerSurface
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var opacity: Double { reduceTransparency ? 1 : min(1, max(drawerSurface ? 0.94 : 0, glassOpacity)) }

    var body: some View {
        // Keep the effect's elevation inside its background layer. A page-wide
        // container otherwise lifts detached glass above unrelated text/fields.
        GlassGroup(spacing: 0) { material }
            .overlay {
                if bordered {
                    shape.stroke(palette.dark ? Color.white.opacity(0.10) : Color.black.opacity(0.09), lineWidth: 0.5)
                }
            }
            .opacity(opacity)
            .background {
                // A floating surface needs to obscure large source text behind
                // it even while the glass itself fades. Both layers follow the
                // component preference and disappear at full transparency.
                if floatingSurface {
                    shape.fill(.regularMaterial).opacity(opacity)
                        .overlay { shape.fill(Color.white.opacity(palette.dark ? 0.08 : 0.24)).opacity(opacity) }
                }
            }
    }

    @ViewBuilder private var material: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            Color.clear.glassEffect(glass, in: shape).glassEffectTransition(.identity)
        } else {
            shape.fill(.regularMaterial)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private var glass: Glass {
        var value = Glass.regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
    }
}

// MARK: - 玻璃容器（26+ 的共享玻璃合并区；旧系统透传）

/// `GlassEffectContainer` 的可用性封装：macOS/iOS 26+ 原样转发共享玻璃合并行为，
/// 旧系统直接透传内容，由内部的 `GlassSurface` 自行落到 `.regularMaterial` 回退。
/// App 最低支持 macOS 15：需要玻璃容器一律走这里，禁止直接使用 GlassEffectContainer。
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing, content: content)
        } else {
            content()
        }
    }
}

private struct LiquidPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color?
    var elevated: Bool
    var bordered = true
    @Environment(\.palette) private var palette
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
    func body(content: Content) -> some View {
        content.clipShape(shape)
            .background {
                GlassSurface(shape: shape, tint: tint, bordered: bordered)
                    .shadow(color: elevated ? Color.black.opacity(palette.dark ? 0.22 : 0.10) : .clear,
                            radius: elevated ? 12 : 0, y: elevated ? 4 : 0)
            }
    }
}

struct LiquidToolModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content.background { GlassSurface(shape: Capsule(), tint: tint, interactive: true) }
    }
}

/// Shared button geometry and glass preference, including prominent actions.
struct LiquidActionButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color? = nil
    var foreground: Color? = nil
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 8
    @Environment(\.palette) private var palette
    @Environment(\.glassOpacity) private var glassOpacity
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground ?? (prominent && glassOpacity > 0.45 ? (tint ?? palette.accent).contrastingForeground : (prominent ? tint ?? palette.accent : palette.gray800)))
            .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
            .background { GlassSurface(shape: Capsule(), tint: prominent ? tint ?? palette.accent : nil, interactive: true) }
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension View {
    /// 页面级 panel:侧栏、主内容卡、首页面板、阅读器右侧卡等。
    func liquidPanel(cornerRadius: CGFloat = CornerRadius.card, tint: Color? = nil, elevated: Bool = false) -> some View {
        modifier(LiquidPanelModifier(cornerRadius: cornerRadius, tint: tint, elevated: elevated))
    }

    /// Nested notices, fields and cards share regular glass and continuous corners.
    func liquidInset(cornerRadius: CGFloat = CornerRadius.inset, tint: Color? = nil, bordered: Bool = true) -> some View {
        modifier(LiquidPanelModifier(cornerRadius: cornerRadius, tint: tint, elevated: false, bordered: bordered))
    }

    /// 浮动工具小件(阅读器悬浮工具条上的单件)。
    func liquidTool(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(LiquidToolModifier(cornerRadius: cornerRadius, tint: tint))
    }

    /// macOS 26+ 的滚动边缘柔光；旧系统无对应效果，原样返回。
    @ViewBuilder
    func liquidScrollEdge(for edges: Edge.Set = .bottom) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
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
    /// 高度取 `WindowChrome.topClearance`(见 App/WindowChrome.swift)这一个固定值:
    /// RootView 已忽略系统顶部安全区,不会出现"安全区 + 补白"双重叠加的空顶栏。
    /// 紧凑页面也消费相同留白;阅读器的分段栏自行避开红绿灯。
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
