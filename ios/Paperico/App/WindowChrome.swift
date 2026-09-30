import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - macOS 红绿灯留白(单一来源)
//
// `.windowStyle(.hiddenTitleBar)` 只是让内容延伸到标题栏之下;实测(见结论)macOS 26+
// 仍会自动保留 **32pt 顶部安全区**,而工程里每个页面又各自硬编码了 34pt 的
// `trafficLightTopPadding` —— 两者叠加成 **66pt** 的空档,红绿灯(14pt,距顶 9pt)
// 孤零零地浮在这条空档上部,看起来就是一块突兀的"独立标题栏区域"。
// 阅读页完全没有加这层 padding,所以切页时顶部还会整体跳动。

private struct TrafficLightClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 需要 **额外** 补在内容顶部的高度(已扣除系统为该窗口保留的部分)。
    /// 由 `RootView` 注入,页面通过 `trafficLightTopPadding()` 消费。
    var trafficLightClearance: CGFloat {
        get { self[TrafficLightClearanceKey.self] }
        set { self[TrafficLightClearanceKey.self] = newValue }
    }
}

#if os(macOS)

enum WindowChrome {
    /// 期望的内容顶部留白(内容顶边到窗口顶边的距离)。
    /// 实测红绿灯为 14pt 直径、距窗口顶 9pt — 34pt 既能容纳按钮又留下呼吸空间。
    static let desiredTopClearance: CGFloat = 34

    // MARK: 留白计算

    /// 系统已经替我们保留的顶部空间 = 标题栏高度 + 内容视图安全区 inset。
    ///
    /// - hiddenTitleBar(fullSizeContentView): 标题栏 0 + 安全区 ≈ 32pt
    /// - 退化成普通 titled 窗口:        标题栏 ≈ 32pt + 安全区 0
    /// 两种形态都能得到同一个值,因此下面的补白公式对两种形态都成立。
    static func reservedTopInset(_ window: NSWindow?) -> CGFloat {
        guard let window, let contentView = window.contentView else { return 0 }
        let titlebarHeight = max(0, window.frame.height - contentView.frame.height)
        return titlebarHeight + contentView.safeAreaInsets.top
    }

    /// 补足到 `desiredTopClearance` 还需要的额外 padding:
    /// 在 macOS 26+ 上约为 2pt,在安全区为 0 的旧系统上为完整的 34pt。
    static var additionalTopClearance: CGFloat {
        max(0, desiredTopClearance - reservedTopInset(appWindow))
    }

    static var appWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { isAppWindow($0) })
    }

    // MARK: 窗口外观

    /// 让整个窗口成为一个连续的画布:没有独立标题栏、窗口背景跟随主题。
    static func apply(to window: NSWindow, baseColor: NSColor) {
        guard isAppWindow(window) else { return }
        // 内容延伸到红绿灯之下,不保留独立的标题栏区域。
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 窗口背景跟随主题色:resize / 窗口出现动画 / 安全区之外的区域
        // 原本是系统 windowBackgroundColor,深浅色切换时会出现一条灰色接缝。
        window.backgroundColor = baseColor
        // 拖动窗口空白处即可移动,红绿灯保持可点击。
        window.isMovableByWindowBackground = true
    }

    static func applyToAll(baseColor: NSColor) {
        for window in NSApp.windows { apply(to: window, baseColor: baseColor) }
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
