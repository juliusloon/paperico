import SwiftUI

/// 工作台导航(floating pill, mirrors layout/WorkspaceNav.tsx)。
/// - 常规:224×44 玻璃圆角矩形;菜单下拉与自身同宽、左缘对齐。
/// - 收起(collapsed):纯圆形 logo 按钮(宽度与 52pt 收起侧栏对齐);
///   阅读器目录收起时仍附加一个圆形目录切换按钮。
/// - 贴底放置(opensUpward)时菜单向上弹出,否则向下弹出。
struct WorkspaceNav: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var systemScheme
    @Environment(AppStore.self) private var appStore
    @Environment(Router.self) private var router

    var collapsed = false
    var currentPaperId: String?
    var onToggleOutline: (() -> Void)? = nil
    var opensUpward = false

    @State private var menuOpen = false

    private var isDark: Bool {
        switch appStore.theme {
        case "dark": return true
        case "light": return false
        default: return systemScheme == .dark
        }
    }

    private struct NavPage: Hashable {
        let page: Router.Page
        let label: String
        let icon: String
        let prefix: String
    }

    private var pages: [NavPage] {
        var items = [
            NavPage(page: .home, label: "首页", icon: Ic.house, prefix: "home"),
            NavPage(page: .library, label: "论文库", icon: Ic.library, prefix: "library"),
            NavPage(page: .methods, label: "方法索引", icon: Ic.layers, prefix: "methods"),
        ]
        if let readerPaperId = currentPaperId ?? router.lastPaperId, !readerPaperId.isEmpty {
            items.append(NavPage(page: .reader(paperId: readerPaperId), label: "阅读器", icon: Ic.bookOpen, prefix: "paper"))
        }
        items.append(NavPage(page: .settings, label: "设置", icon: Ic.settings, prefix: "settings"))
        return items
    }

    private func isActive(_ item: NavPage) -> Bool {
        switch item.page {
        case .home: return router.page == .home
        case .reader(let paperId):
            if case .reader(let current) = router.page { return current == paperId }
            return false
        default:
            return item.prefix == prefix(of: router.page)
        }
    }

    private func prefix(of page: Router.Page) -> String {
        switch page {
        case .home: return "home"
        case .library: return "library"
        case .methods: return "methods"
        case .settings: return "settings"
        case .reader: return "paper"
        }
    }

    var body: some View {
        Group {
            if collapsed {
                // 收起态:圆形按钮各自携带玻璃表面
                navContent
            } else {
                navContent
                    .modifier(NavPillSurface(collapsed: false))
            }
        }
        .overlay(alignment: opensUpward ? .bottomLeading : .topLeading) {
            if menuOpen {
                pageMenu
                    .offset(y: opensUpward ? -(44 + 8) : (44 + 8))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: menuOpen)
        .animation(.easeInOut(duration: 0.18), value: collapsed)
        .background {
            // 点击菜单以外任意区域关闭(覆盖整窗,在菜单层之下)
            if menuOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { menuOpen = false }
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var navContent: some View {
        if collapsed {
            HStack(spacing: 4) {
                circularButton(systemName: Ic.feather, tint: palette.accent, help: "展开工作台导航") {
                    menuOpen.toggle()
                }
                if let onToggleOutline {
                    circularButton(
                        systemName: Ic.panelLeft,
                        tint: palette.gray500,
                        help: "展开结构目录",
                        action: onToggleOutline
                    )
                }
            }
        } else {
            HStack(spacing: 3) {
                brandButton
                Spacer(minLength: 0)
                RoundIconButton(
                    systemName: isDark ? Ic.sun : Ic.moon,
                    size: 32,
                    title: isDark ? "切换亮色" : "切换暗色"
                ) {
                    appStore.setTheme(isDark ? "light" : "dark")
                }
                if let onToggleOutline {
                    RoundIconButton(
                        systemName: Ic.panelLeftClose,
                        size: 32,
                        title: "收起结构目录"
                    ) {
                        onToggleOutline()
                    }
                }
            }
            .padding(4)
            .frame(width: 224, height: 44)
        }
    }

    private func circularButton(systemName: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.ic(systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .modifier(NavPillSurface(collapsed: true))
        .help(help)
    }

    /// macOS 26+ / iOS 26+ 走系统 Liquid Glass;旧系统保持原有手绘浮标外观。
    private struct NavPillSurface: ViewModifier {
        var collapsed: Bool
        @Environment(\.palette) private var palette

        func body(content: Content) -> some View {
            #if os(macOS)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                legacy(content)
            }
            #elseif os(iOS)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                legacy(content)
            }
            #else
            legacy(content)
            #endif
        }

        private var shape: AnyShape {
            collapsed ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 13))
        }

        private func legacy(_ content: Content) -> some View {
            content
                .background(
                    RoundedRectangle(cornerRadius: 13)
                        .fill(palette.gray0.opacity(0.92))
                        .background(.ultraThinMaterial, in: shapeForMaterial)
                )
                .overlay(shapeForMaterial.stroke(palette.gray300.opacity(0.72)))
                .shadow(color: palette.shadowFloat, radius: 14, y: 5)
        }

        private var shapeForMaterial: RoundedRectangle {
            RoundedRectangle(cornerRadius: collapsed ? 22 : 13)
        }
    }

    private var brandButton: some View {
        Button {
            menuOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Image.ic(Ic.feather)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(palette.accent))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paperico")
                        .font(.reading(13, weight: .semibold))
                        .foregroundStyle(palette.gray800)
                    Text("RESEARCH DESK")
                        .font(.mono(7, weight: .bold))
                        .kerning(0.7)
                        .foregroundStyle(palette.gray400)
                }
                Image.ic(Ic.chevronDown)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.gray400)
                    .rotationEffect(.degrees(menuOpen ? 180 : 0))
            }
            .padding(.leading, 3)
            .padding(.trailing, 7)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .help("展开工作台导航")
    }

    /// 下拉页面菜单:与导航栏同宽(224)、左缘对齐,玻璃圆角矩形。
    private var pageMenu: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(pages, id: \.self) { item in
                Button {
                    router.go(item.page)
                    menuOpen = false
                } label: {
                    HStack(spacing: 8) {
                        Image.ic(item.icon)
                            .font(.system(size: 13))
                            .frame(width: 20)
                            .foregroundStyle(isActive(item) ? palette.accent : palette.gray600)
                        Text(item.label)
                            .font(.system(size: 13))
                            .foregroundStyle(isActive(item) ? palette.accent : palette.gray600)
                        Spacer(minLength: 0)
                        if isActive(item) {
                            Text("当前")
                                .font(.system(size: 10))
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 8).fill(isActive(item) ? palette.accentSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noFocusRing()
            }
        }
        .padding(8)
        .frame(width: 224, alignment: .leading)
        .modifier(MenuSurface())
    }

    /// 菜单面板表面:macOS 26+ 用 Liquid Glass,旧系统回退到手绘浮层。
    private struct MenuSurface: ViewModifier {
        @Environment(\.palette) private var palette

        func body(content: Content) -> some View {
            #if os(macOS)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 13))
            } else {
                legacy(content)
            }
            #elseif os(iOS)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 13))
            } else {
                legacy(content)
            }
            #else
            legacy(content)
            #endif
        }

        private func legacy(_ content: Content) -> some View {
            content
                .background(RoundedRectangle(cornerRadius: 13).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.gray200))
                .shadow(color: palette.shadowFloat, radius: 18, y: 8)
        }
    }
}
