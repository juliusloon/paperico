import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - macOS 红绿灯留白(单一来源)
//
// `.windowStyle(.hiddenTitleBar)` + fullSizeContentView 之后,红绿灯(14pt,距顶 9pt,
// 底缘 23pt)悬浮在窗口左上角。macOS 26+ 仍会给 SwiftUI 内容顶部保留 ~32pt 安全区,
// 旧实现又在其上叠加补白,顶栏形成一大块空档。现在 RootView 忽略系统顶部安全区,
// 页面统一消费 30pt 补白,在原有紧凑布局上多留 8pt,保持面板原有外观。

private struct TrafficLightClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 页面内容顶部需要补的留白(由 `RootView` 注入,页面通过 `trafficLightTopPadding()` 消费)。
    var trafficLightClearance: CGFloat {
        get { self[TrafficLightClearanceKey.self] }
        set { self[TrafficLightClearanceKey.self] = newValue }
    }
}

#if os(macOS)

enum WindowChrome {
    /// 内容顶部到窗口顶边的固定补白(页面自身的外边距另计,见上文换算)。
    static let topClearance: CGFloat = 30

    // MARK: 窗口外观

    /// 让整个窗口成为一个连续的画布:没有独立标题栏、窗口背景跟随主题。
    static func apply(to window: NSWindow, baseColor: NSColor, opacity: Double) {
        guard isAppWindow(window) else { return }
        // 内容延伸到红绿灯之下,不保留独立的标题栏区域。
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // AppKit owns the single window canvas so its rounded frame and shadow
        // use the same silhouette. A clear native background with a white
        // hosting-view fill leaves an edge seam and a stale alpha-based shadow.
        let alpha = min(1, max(0, opacity))
        window.backgroundColor = baseColor.withAlphaComponent(alpha)
        window.isOpaque = alpha == 1
        window.hasShadow = true
        // 拖动窗口空白处即可移动,红绿灯保持可点击。
        window.isMovableByWindowBackground = true
        window.invalidateShadow()
        // Recompute after the hosting view has committed its appearance update.
        DispatchQueue.main.async { [weak window] in window?.invalidateShadow() }
    }

    static func applyToAll(baseColor: NSColor, opacity: Double) {
        for window in NSApp.windows { apply(to: window, baseColor: baseColor, opacity: opacity) }
    }

    // MARK: 私有

    /// 只处理真正的应用窗口,跳过 SwiftUI popover / 辅助面板(utility / HUD)。
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        let mask = window.styleMask
        guard !mask.contains(.utilityWindow), !mask.contains(.hudWindow) else { return false }
        return mask.contains(.titled) && mask.contains(.resizable)
    }
}

#endif
