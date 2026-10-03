import SwiftUI

private enum WorkspaceNavMetrics {
    static let railWidth: CGFloat = 52
    static let expandedWidth: CGFloat = 224
    static let barHeight: CGFloat = 52
}

/// The page reserves only the bottom bar's footprint. The root draws its glass
/// above every content layer, with extra menu content growing upward in place.
struct WorkspaceNav: View {
    var collapsed: Bool? = nil
    var enabled = true
    var currentPaperId: String?
    var includesDirectory = false
    var surfaceScheme: ColorScheme?

    @Environment(\.containerWidth) private var containerWidth

    @State private var sourceId = UUID()
    @State private var section: WorkspaceMenuSection?

    private var isCollapsed: Bool { collapsed ?? (containerWidth < LayoutBreakpoint.workspace) }

    var body: some View {
        Color.clear
            .frame(width: isCollapsed ? WorkspaceNavMetrics.railWidth : WorkspaceNavMetrics.expandedWidth,
                   height: WorkspaceNavMetrics.barHeight)
            .anchorPreference(key: WorkspaceMenuPreferenceKey.self, value: .bounds) { anchor in
                [WorkspaceMenuRequest(id: sourceId, anchor: anchor, section: section,
                                      collapsed: isCollapsed, enabled: enabled, currentPaperId: currentPaperId,
                                      includesDirectory: includesDirectory, surfaceScheme: surfaceScheme,
                                      dismiss: { section = nil }, toggle: { next in
                                          section = section == next ? nil : next
                                      })]
            }
            .onChange(of: enabled) { _, active in if !active { section = nil } }
            .accessibilityHidden(true)
    }
}

enum WorkspaceMenuSection { case pages, directory }

struct WorkspaceMenuRequest: Identifiable {
    let id: UUID
    let anchor: Anchor<CGRect>
    let section: WorkspaceMenuSection?
    let collapsed: Bool
    let enabled: Bool
    let currentPaperId: String?
    let includesDirectory: Bool
    let surfaceScheme: ColorScheme?
    let dismiss: () -> Void
    let toggle: (WorkspaceMenuSection) -> Void
}

struct WorkspaceMenuPreferenceKey: PreferenceKey {
    static var defaultValue: [WorkspaceMenuRequest] { [] }
    static func reduce(value: inout [WorkspaceMenuRequest], nextValue: () -> [WorkspaceMenuRequest]) {
        value.append(contentsOf: nextValue())
    }
}

struct WorkspaceMenuOverlay: View {
    let requests: [WorkspaceMenuRequest]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(Router.self) private var router

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if requests.contains(where: { $0.section != nil }) {
                    OutsideDismissArea(label: "收起底部菜单") { dismissAll() }
                }
                GlassEffectContainer(spacing: 0) {
                    ForEach(requests) { request in
                        let anchor = geometry[request.anchor]
                        let isCompactButton = request.collapsed && request.section == nil
                        let width = min(isCompactButton ? WorkspaceNavMetrics.railWidth : WorkspaceNavMetrics.expandedWidth,
                                        geometry.size.width - anchor.minX - 14)
                        let available = max(WorkspaceNavMetrics.barHeight, anchor.maxY - 44)
                        let rows = request.currentPaperId == nil && router.lastPaperId == nil ? 4 : 5
                        let height: CGFloat = switch request.section {
                        case .pages: min(available, WorkspaceNavMetrics.barHeight + 24 + CGFloat(rows) * 43)
                        case .directory: min(available, 520)
                        case nil: WorkspaceNavMetrics.barHeight
                        }
                        WorkspaceNavSurface(request: request)
                            .environment(\.colorScheme, request.surfaceScheme ?? colorScheme)
                            .disabled(!request.enabled)
                            .frame(width: width, height: height, alignment: .bottomLeading)
                            // The bottom edge stays at the bar's original position.
                            .position(x: anchor.minX + width / 2, y: anchor.maxY - height / 2)
                            .transition(.opacity)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: request.section)
                            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: request.collapsed)
                    }
                }
            }
            .onExitCommand { dismissAll() }
        }
    }

    private func dismissAll() { requests.forEach { $0.dismiss() } }
}

private struct WorkspaceNavSurface: View {
    let request: WorkspaceMenuRequest
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppStore.self) private var appStore
    @Environment(Router.self) private var router
    @Environment(ReaderStore.self) private var readerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool {
        switch appStore.theme {
        case "dark": true
        case "light": false
        default: colorScheme == .dark
        }
    }


    private struct NavPage: Identifiable {
        let page: Router.Page
        let label: String
        let icon: String
        var id: String { label }
    }

    private var pages: [NavPage] {
        var items = [
            NavPage(page: .home, label: "首页", icon: Ic.house),
            NavPage(page: .library, label: "论文库", icon: Ic.library),
            NavPage(page: .methods, label: "方法索引", icon: Ic.layers)
        ]
        if let id = request.currentPaperId ?? router.lastPaperId, !id.isEmpty {
            items.append(NavPage(page: .reader(paperId: id), label: "阅读器", icon: Ic.bookOpen))
        }
        items.append(NavPage(page: .settings, label: "设置", icon: Ic.settings))
        return items
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let section = request.section {
                Group {
                    switch section {
                    case .pages: pageMenu
                    case .directory: directory
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, WorkspaceNavMetrics.barHeight + 4)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .liquidPanel(cornerRadius: isCompactButton ? WorkspaceNavMetrics.barHeight / 2 : 24)
        .environment(\.floatingSurface, true)
    }

    private var isCompactButton: Bool { request.collapsed && request.section == nil }

    @ViewBuilder private var bottomBar: some View {
        if isCompactButton {
            Button { request.toggle(.pages) } label: {
                brandIcon.frame(width: WorkspaceNavMetrics.railWidth, height: WorkspaceNavMetrics.barHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).noFocusRing()
            .help("展开工作台导航").accessibilityLabel("展开工作台导航")
        } else {
            expandedBottomBar
        }
    }

    private var brandIcon: some View {
        Image("PapericoMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 28)
            .foregroundStyle(palette.accent)
            .frame(width: 36, height: 36)
    }

    /// The bar stays fixed while additional page or directory rows grow upward.
    private var expandedBottomBar: some View {
        HStack(spacing: 4) {
            Button { request.toggle(.pages) } label: {
                HStack(spacing: 7) {
                    brandIcon
                    Text("Paperico").font(.reading(15, weight: .semibold))
                        .lineLimit(1).minimumScaleFactor(0.85)
                        .foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    Image.ic(Ic.chevronDown).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(request.section == .pages ? 180 : 0))
                }.frame(height: 36).contentShape(Rectangle())
            }.help("展开工作台导航").accessibilityLabel("展开工作台导航")
            Group {
                if request.includesDirectory {
                    Button { request.toggle(.directory) } label: {
                        Image.ic(Ic.listTree).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary).frame(width: 32, height: 32)
                    }.help("展开或收起论文逻辑链目录")
                        .accessibilityLabel("论文逻辑链目录")
                        .accessibilityValue(request.section == .directory ? "已展开" : "已收起")
                } else { Color.clear.frame(width: 32, height: 32).accessibilityHidden(true) }
            }
            RoundIconButton(systemName: isDark ? Ic.sun : Ic.moon, size: 32,
                            title: isDark ? "切换亮色" : "切换暗色", foreground: .primary) {
                appStore.setTheme(isDark ? "light" : "dark")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: WorkspaceNavMetrics.expandedWidth,
               height: WorkspaceNavMetrics.barHeight, alignment: .leading)
        .buttonStyle(.plain).noFocusRing()
    }

    private var pageMenu: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(pages) { item in
                    Button {
                        request.dismiss()
                        router.go(item.page)
                    } label: {
                        HStack(spacing: 8) {
                            Image.ic(item.icon).font(.system(size: 13)).frame(width: 20)
                            Text(item.label).font(.system(size: 13))
                            Spacer(minLength: 0)
                            if item.page == router.page {
                                Text("当前").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9).frame(height: 40)
                        .background(Color.primary.opacity(item.page == router.page ? 0.07 : 0),
                                    in: RoundedRectangle(cornerRadius: CornerRadius.inset))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).noFocusRing()
                }
            }.padding(8)
        }
        .scrollIndicators(.hidden)
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("论文逻辑链").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(readerStore.outlineEntries.count) 个节点")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.top, 15).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(readerStore.outlineEntries) { entry in
                        if let block = readerStore.paper?.blocks.first(where: { $0.id == entry.blockId }) {
                        Button {
                            readerStore.scrollToBlock(block.id)
                            request.dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if let page = block.pageIdx {
                                    Text("第 \(page + 1) 页").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(entry.title)
                                    .font(.system(size: entry.heading ? (entry.level == 1 ? 16 : 14.5) : 13.5,
                                                  weight: entry.heading ? .semibold : .regular))
                                    .lineLimit(3).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9).padding(.leading, CGFloat(entry.level - 1) * 10)
                            .background(Color.primary.opacity(block.id == readerStore.activeBlockId ? 0.07 : 0),
                                        in: RoundedRectangle(cornerRadius: CornerRadius.inset))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).noFocusRing()
                        }
                    }
                }.padding(.horizontal, 6).padding(.bottom, 8)
            }
        }
        .foregroundStyle(.primary)
    }
}

/// One desktop layout at every width. A narrow window keeps the same sidebar
/// rail; expanding it reserves its own column until the user clicks outside.
struct WorkspaceSplitLayout<Sidebar: View, Content: View>: View {
    var compact: Bool
    var collapsed: Bool
    @Binding var temporarilyExpanded: Bool
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.trafficLightClearance) private var trafficLightClearance
    @Environment(\.palette) private var palette

    private var railCollapsed: Bool { compact ? !temporarilyExpanded : collapsed }
    private var reservedWidth: CGFloat {
        railCollapsed ? WorkspaceNavMetrics.railWidth : WorkspaceNavMetrics.expandedWidth
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the compact page at its rail-layout width while the sidebar
            // pushes it out of the viewport. Reflowing into the remaining sliver
            // lets intrinsic toolbar/grid widths displace the sidebar at 490 pt.
            let contentWidth = max(0, geometry.size.width - 12 -
                (compact ? WorkspaceNavMetrics.railWidth : reservedWidth))
            ZStack(alignment: .leading) {
                GlassEffectContainer(spacing: 4) {
                    HStack(alignment: .top, spacing: 12) {
                        Color.clear.frame(width: reservedWidth)
                        content().frame(width: contentWidth, height: geometry.size.height)
                            .disabled(compact && temporarilyExpanded)
                            .accessibilityHidden(compact && temporarilyExpanded)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                }
                .blur(radius: compact && temporarilyExpanded ? 3 : 0)
                .clipped()
                if compact && temporarilyExpanded {
                    OutsideDismissArea(label: "点击空白收起侧栏", dimOpacity: palette.dark ? 0.22 : 0.12) {
                        temporarilyExpanded = false
                    }
                    .padding(-14)
                    .transition(.opacity)
                }
                GlassEffectContainer(spacing: 4) {
                    VStack(alignment: .leading, spacing: 12) {
                        sidebar().frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, max(0, trafficLightClearance - 8))
                        WorkspaceNav(collapsed: compact || collapsed, enabled: !compact || !temporarilyExpanded)
                    }
                }
                .frame(width: reservedWidth)
                .zIndex(1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .padding(14)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: railCollapsed)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: temporarilyExpanded)
        .onChange(of: compact) { _, _ in temporarilyExpanded = false }
        .onExitCommand { temporarilyExpanded = false }
    }
}

/// A real control prevents window-background dragging from swallowing a click
/// intended to dismiss an overlay in a titlebar-free workspace.
struct OutsideDismissArea: View {
    let label: String
    var dimOpacity: Double = 0
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Color.black.opacity(dimOpacity).contentShape(Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain).noFocusRing()
        .accessibilityLabel(label)
    }
}
