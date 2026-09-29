import SwiftUI

/// Mirrors projects/MethodsPage.tsx — category sidebar, search, expandable method cards.
struct MethodsPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Router.self) private var router

    @Environment(\.apiClient) private var client

    @State private var items: [MethodIndexItem] = []
    @State private var loading = true
    @State private var query = ""
    @State private var categoryFilter = ""
    @State private var sidebarCollapsed = false
    @State private var mobileSidebarOpen = false

    private var isCompact: Bool { sizeClass == .compact }
    private var effectiveSidebarCollapsed: Bool { sidebarCollapsed && !isCompact }

    private var categoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.category, default: 0] += 1 }
        return counts
    }

    private var categories: [(key: String, label: String, count: Int)] {
        MethodCategory.labels.compactMap { key, label in
            guard let count = categoryCounts[key], count > 0 else { return nil }
            return (key, label, count)
        }
    }

    private var filteredItems: [MethodIndexItem] {
        categoryFilter.isEmpty ? items : items.filter { $0.category == categoryFilter }
    }

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 0) {
                    compactTopBar
                    mainColumn
                }
                .background(palette.gray0)
                .overlay { if mobileSidebarOpen { drawerLayer } }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 70)
                        sidebar
                    }
                    .frame(width: sidebarCollapsed ? 52 : 224)
                    mainColumn
                }
                .padding(14)
                .background(palette.gray0)
            }
        }
        .task { await load(query: nil) }
    }

    private func load(query q: String?) async {
        loading = true
        defer { loading = false }
        items = (try? await client.libraryMethods(category: categoryFilter.isEmpty ? nil : categoryFilter, q: q)) ?? items
    }

    private func selectCategory(_ category: String) {
        categoryFilter = category
        withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = false }
        Task { await load(query: query.isEmpty ? nil : query) }
    }

    // MARK: chrome

    private var compactTopBar: some View {
        HStack(spacing: 8) {
            WorkspaceNav(collapsed: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 56)
        .background(palette.gray0)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }
    }

    private var drawerLayer: some View {
        ZStack(alignment: .leading) {
            Color(hex: "#111419")!.opacity(0.38)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = false } }
            sidebar
                .frame(width: 188)
                .transition(.move(edge: .leading))
                .padding(.vertical, 8)
                .padding(.leading, 8)
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                if !effectiveSidebarCollapsed {
                    Text("实体类别")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.gray800)
                }
                Spacer(minLength: 0)
                RoundIconButton(
                    systemName: isCompact ? Ic.close : (sidebarCollapsed ? Ic.panelLeft : Ic.panelLeftClose),
                    size: 30,
                    title: isCompact ? "关闭实体类别" : (sidebarCollapsed ? "展开类别" : "收起类别")
                ) {
                    if isCompact {
                        withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = false }
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed.toggle() }
                    }
                }
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 50)

            if !effectiveSidebarCollapsed {
                ScrollView {
                    VStack(spacing: 2) {
                        categoryRow(key: "", label: "全部方法", count: items.count, color: nil)
                        ForEach(categories, id: \.key) { category in
                            categoryRow(key: category.key, label: category.label, count: category.count, color: MethodCategory.color(category.key))
                        }
                    }
                    .padding(8)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.gray0))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.gray300.opacity(0.68)))
        .shadow(color: palette.shadowCard, radius: 8, y: 3)
    }

    private func categoryRow(key: String, label: String, count: Int, color: Color?) -> some View {
        let active = categoryFilter == key
        return Button {
            selectCategory(key)
        } label: {
            HStack(spacing: 8) {
                if let color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(active ? palette.accent : palette.gray700)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)").font(.system(size: 10)).foregroundStyle(palette.gray500.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? palette.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: main

    private var mainColumn: some View {
        VStack(spacing: 0) {
            toolbar
            contentArea
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.gray0))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.gray300.opacity(0.68)))
        .shadow(color: palette.shadowCard, radius: 8, y: 3)
        .padding(isCompact ? 8 : 0)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if isCompact {
                RoundIconButton(systemName: Ic.layers, size: 38, title: "实体类别") {
                    withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = true }
                }
            }
            if !isCompact {
                VStack(alignment: .leading, spacing: 3) {
                    Text("METHOD INDEX").font(.mono(8, weight: .bold)).kerning(1.2).foregroundStyle(palette.accent)
                    Text("方法索引").font(.reading(22, weight: .medium)).foregroundStyle(palette.gray900)
                }
                .frame(width: 118, alignment: .leading)
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Image.ic(Ic.search).font(.system(size: 13)).foregroundStyle(palette.gray400).padding(.leading, 8)
                    TextField("搜索方法名称...", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5))
                        .padding(.leading, 5)
                        .padding(.trailing, 10)
                        .onSubmit { Task { await load(query: query.isEmpty ? nil : query) } }
                }
                .frame(height: 38)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray300))

                Button {
                    Task { await load(query: query.isEmpty ? nil : query) }
                } label: {
                    Text("搜索")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9).fill(palette.accent))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 50)
    }

    @ViewBuilder
    private var contentArea: some View {
        ScrollView {
            if loading {
                HStack(alignment: .top, spacing: 12) {
                    SkeletonCard(); SkeletonCard(); SkeletonCard(); SkeletonCard()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            } else if filteredItems.isEmpty {
                VStack(spacing: 12) {
                    Image.ic(Ic.layers).font(.system(size: 42)).foregroundStyle(palette.gray400.opacity(0.3))
                    Text("暂无方法索引").font(.system(size: 16.5)).foregroundStyle(palette.gray600)
                    Text("上传并分析论文后,方法实体将自动归集于此").font(.system(size: 13)).foregroundStyle(palette.gray500)
                }
                .frame(maxWidth: .infinity, minHeight: 380)
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(filteredItems) { item in
                        MethodCard(item: item)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Method card

struct MethodCard: View {
    @Environment(\.palette) private var palette
    @Environment(Router.self) private var router

    let item: MethodIndexItem

    @State private var expanded = false

    private var categoryColor: Color { MethodCategory.color(item.category) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(categoryColor).frame(width: 8, height: 8)
                        Text(item.name)
                            .font(.reading(16.5, weight: .semibold))
                            .foregroundStyle(palette.gray800)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.definitionZh.isEmpty {
                        Text(item.definitionZh)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(palette.gray600)
                            .padding(.leading, 16)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(MethodCategory.label(item.category))
                        .font(.system(size: 11))
                        .foregroundStyle(categoryColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(categoryColor.chipBackground()))
                    Text("\(item.papers.count) 篇论文")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.gray500)
                }
            }

            if expanded {
                VStack(spacing: 4) {
                    ForEach(item.papers, id: \.paperId) { paper in
                        Button {
                            router.go(.reader(paperId: paper.paperId))
                        } label: {
                            HStack(spacing: 8) {
                                Text(paper.title)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(palette.accent)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(paper.blockIds.count) 处")
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.accent.opacity(0.6))
                            }
                            .padding(.horizontal, 8)
                            .frame(minHeight: 34)
                            .background(RoundedRectangle(cornerRadius: 6).fill(palette.accentSoft))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(17)
        .frame(minHeight: 142, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.gray0))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.gray300.opacity(0.66)))
        .shadow(color: palette.shadowCard, radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
    }
}

// MARK: - ApiClient environment (pages outside the stores need direct calls)

private struct ApiClientKey: EnvironmentKey {
    static let defaultValue = ApiClient()
}

extension EnvironmentValues {
    var apiClient: ApiClient {
        get { self[ApiClientKey.self] }
        set { self[ApiClientKey.self] = newValue }
    }
}
