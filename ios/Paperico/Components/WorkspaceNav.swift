import SwiftUI

/// Floating workspace navigation pill (mirrors layout/WorkspaceNav.tsx).
/// Home uses it inside a 72px nav row; workspace pages float it over content;
/// the reader shows a collapsed variant with the outline toggle.
struct WorkspaceNav: View {
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var systemScheme
    @Environment(AppStore.self) private var appStore
    @Environment(Router.self) private var router

    var collapsed = false
    var currentPaperId: String?
    var onToggleOutline: (() -> Void)? = nil

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
        HStack(spacing: 3) {
            brandButton
            Spacer(minLength: 0)
            if !collapsed {
                RoundIconButton(
                    systemName: isDark ? Ic.sun : Ic.moon,
                    size: 32,
                    title: isDark ? "切换亮色" : "切换暗色"
                ) {
                    appStore.setTheme(isDark ? "light" : "dark")
                }
            }
            if let onToggleOutline {
                RoundIconButton(
                    systemName: collapsed ? Ic.panelLeft : Ic.panelLeftClose,
                    size: 32,
                    title: collapsed ? "展开结构目录" : "收起结构目录"
                ) {
                    onToggleOutline()
                }
            }
        }
        .padding(4)
        .frame(width: collapsed ? 92 : 224, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(palette.gray0.opacity(0.92))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(palette.gray300.opacity(0.72))
        )
        .shadow(color: palette.shadowFloat, radius: 14, y: 5)
        .popover(isPresented: $menuOpen, attachmentAnchor: .point(.bottomLeading), arrowEdge: .bottom) {
            pageMenu
                .presentationCompactAdaptation(.popover)
                .frame(width: 224)
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
                if !collapsed {
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
            }
            .padding(.leading, 3)
            .padding(.trailing, 7)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("展开工作台导航")
    }

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
            }
        }
        .padding(8)
        .background(palette.gray0)
    }
}

// MARK: - Nav slot container (mirrors TopBar.tsx page-nav-slot)

/// Home embeds the pill in an in-flow 72px row; workspace pages float it absolutely.
struct HomeNavSlot: View {
    var body: some View {
        HStack {
            WorkspaceNav()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .frame(height: 72, alignment: .top)
    }
}
