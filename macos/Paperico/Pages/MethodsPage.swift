import SwiftUI
import UniformTypeIdentifiers

/// Mirrors projects/MethodsPage.tsx — category sidebar, search, expandable method cards.
/// 窄窗口沿用桌面侧栏轨道，展开后点击空白收回。
struct MethodsPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(AppServices.self) private var services

    @State private var error = ""
    @State private var items: [MethodIndexItem] = []
    @State private var loading = true
    @State private var query = ""
    @State private var categoryFilter = ""
    @State private var sidebarCollapsed = false
    @State private var temporarilyExpanded = false
    @State private var sortMode = "recent"
    @State private var selectionMode = false
    @State private var selectedIds: [String] = []
    @State private var editingId: String?
    @State private var deletingItem: MethodIndexItem?
    @State private var mergeItems: [MethodIndexItem]?
    @State private var saving = false
    @State private var groups: [MethodGroup] = MethodGroup.presets
    @State private var showNewGroup = false
    @State private var groupName = ""
    @State private var renamingGroup: String?
    @State private var deletingGroup: MethodGroup?
    @State private var groupBusy = false
    @State private var dropTarget: String?


    private var isCompact: Bool { containerWidth < LayoutBreakpoint.workspace }
    private var effectiveSidebarCollapsed: Bool { isCompact ? !temporarilyExpanded : sidebarCollapsed }

    private var categoryCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.category, default: 0] += 1 }
        return counts
    }

    private var filteredItems: [MethodIndexItem] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter {
            (categoryFilter.isEmpty || $0.category == categoryFilter) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            if sortMode == "name" {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            if $0.addedAt != $1.addedAt { return ($0.addedAt ?? "") > ($1.addedAt ?? "") }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        WorkspaceSplitLayout(compact: isCompact, collapsed: sidebarCollapsed, temporarilyExpanded: $temporarilyExpanded) {
            sidebar
        } content: {
            mainColumn
        }
        .task { await load() }
        .accessibilityHidden(mergeItems != nil)
        .overlay {
            if let mergeItems {
                GeometryReader { geometry in
                    ZStack {
                        OutsideDismissArea(label: "取消合并方法", dimOpacity: palette.dark ? 0.28 : 0.12) {
                            if !saving { self.mergeItems = nil }
                        }
                        MethodMergePanel(items: mergeItems, saving: saving, onCancel: {
                            if !saving { self.mergeItems = nil }
                        }) { target, name, definition in
                            Task { await merge(mergeItems, keeping: target, name: name, definition: definition) }
                        }
                        .frame(width: min(540, max(0, geometry.size.width - 40)))
                        .frame(height: min(520, max(280, geometry.size.height - 48)))
                    }
                }.transition(.opacity)
            }
        }
        .alert("删除方法分组", isPresented: .init(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
            Button("取消", role: .cancel) { deletingGroup = nil }
            Button("删除", role: .destructive) { Task { await deleteGroup() } }
        } message: {
            Text("删除「\(deletingGroup?.name ?? "")」会同时删除里面的所有方法条目。论文原文和解析结果会保留。此操作无法撤销。")
        }
        .alert("方法索引", isPresented: .init(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
            Button("好") { error = "" }
        } message: { Text(error) }
        .alert("删除方法条目", isPresented: .init(get: { deletingItem != nil }, set: { if !$0 { deletingItem = nil } })) {
            Button("取消", role: .cancel) { deletingItem = nil }
            Button("删除", role: .destructive) {
                if let item = deletingItem { Task { await delete(item) } }
            }
        } message: { Text("从方法索引删除「\(deletingItem?.name ?? "")」。论文原文和解析结果会保留。") }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            items = try await services.library.methodIndex()
            groups = await services.library.listMethodGroups()
            if !categoryFilter.isEmpty && !groups.contains(where: { $0.id == categoryFilter }) { categoryFilter = "" }
            selectedIds.removeAll { id in !items.contains { $0.id == id } }
        } catch {
            self.error = ApiFailure.wrap(error).errorDescription ?? "方法索引读取失败"
        }
    }

    private func selectCategory(_ category: String) {
        categoryFilter = category
        withAnimation(.easeInOut(duration: 0.18)) { temporarilyExpanded = false }
    }

    private func toggleSelection(_ id: String) {
        selectionMode = true
        if selectedIds.contains(id) { selectedIds.removeAll { $0 == id } }
        else { selectedIds.append(id) }
    }

    private func save(_ item: MethodIndexItem, name: String, definition: String) async {
        saving = true
        defer { saving = false }
        do {
            try await services.library.editMethod(key: item.id, name: name, definitionZh: definition)
            editingId = nil
            await load()
        } catch { self.error = ApiFailure.wrap(error).localizedDescription }
    }

    private func delete(_ item: MethodIndexItem) async {
        do {
            try await services.library.deleteMethod(key: item.id)
            deletingItem = nil
            await load()
        } catch { self.error = ApiFailure.wrap(error).localizedDescription }
    }

    private func merge(_ pair: [MethodIndexItem], keeping target: String, name: String, definition: String) async {
        saving = true
        defer { saving = false }
        do {
            try await services.library.mergeMethods(keys: pair.map(\.id), keeping: target, name: name, definitionZh: definition)
            mergeItems = nil
            selectedIds = []; selectionMode = false
            await load()
        } catch { self.error = ApiFailure.wrap(error).localizedDescription }
    }

    private func saveGroup() async {
        guard !groupBusy else { return }
        groupBusy = true
        defer { groupBusy = false }
        do {
            if let id = renamingGroup { try await services.library.renameMethodGroup(id: id, name: groupName) }
            else { _ = try await services.library.createMethodGroup(name: groupName) }
            cancelGroupEdit()
            await load()
        } catch { self.error = ApiFailure.wrap(error).localizedDescription }
    }

    private func cancelGroupEdit() { renamingGroup = nil; showNewGroup = false; groupName = "" }

    private func deleteGroup() async {
        guard let group = deletingGroup, !groupBusy else { return }
        groupBusy = true
        defer { groupBusy = false }
        do {
            try await services.library.deleteMethodGroup(id: group.id)
            deletingGroup = nil
            await load()
        } catch { self.error = ApiFailure.wrap(error).localizedDescription }
    }

    private func move(_ ids: [String], to group: String) async {
        guard !groupBusy else { return }
        groupBusy = true
        defer { groupBusy = false }
        do {
            try await services.library.moveMethods(keys: ids, groupId: group)
            selectedIds = []; selectionMode = false
            await load()
        } catch { self.error = ApiFailure.wrap(error).localizedDescription }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                if !effectiveSidebarCollapsed {
                    Text("方法分组").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.gray800)
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if !effectiveSidebarCollapsed {
                        RoundIconButton(systemName: Ic.plus, size: 30, title: "新建方法分组") {
                            cancelGroupEdit(); showNewGroup = true
                        }
                    }
                    RoundIconButton(systemName: Ic.panelLeft, size: 30,
                        title: effectiveSidebarCollapsed ? "展开方法分组" : "收起方法分组", animatesSymbolChange: false) {
                        if isCompact { temporarilyExpanded.toggle() }
                        else { withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed.toggle() } }
                    }
                }
            }.padding(.horizontal, effectiveSidebarCollapsed ? 11 : 15).frame(minHeight: 50)
            if !effectiveSidebarCollapsed {
                if showNewGroup {
                    WorkspaceGroupEditor(name: $groupName, creating: true, busy: groupBusy,
                        onSave: { Task { await saveGroup() } }, onCancel: cancelGroupEdit)
                        .padding(.horizontal, 8).padding(.bottom, 6)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        WorkspaceGroupRow(name: "全部方法", count: items.count, active: categoryFilter.isEmpty,
                            onSelect: { selectCategory("") })
                        ForEach(groups) { group in
                            if renamingGroup == group.id {
                                WorkspaceGroupEditor(name: $groupName, busy: groupBusy,
                                    onSave: { Task { await saveGroup() } }, onCancel: cancelGroupEdit)
                            } else {
                                WorkspaceGroupRow(name: group.name, count: categoryCounts[group.id] ?? 0,
                                    active: categoryFilter == group.id, color: MethodCategory.color(group.id, dark: palette.dark),
                                    targeted: dropTarget == group.id, onSelect: { selectCategory(group.id) },
                                    onRename: { cancelGroupEdit(); renamingGroup = group.id; groupName = group.name },
                                    onDelete: { deletingGroup = group })
                                #if os(macOS)
                                .onDrop(of: [WorkspaceDragKind.methods.type], delegate: WorkspaceGroupDropDelegate(kind: .methods, target: $dropTarget, groupId: group.id) { ids in
                                    Task { await move(ids, to: group.id) }
                                })
                                #endif
                            }
                        }
                    }.padding(8)
                }
            } else { Spacer(minLength: 0) }
        }.clipped().liquidPanel(elevated: true)
    }

    // MARK: main

    private var mainColumn: some View {
        VStack(spacing: 0) {
            toolbar
            if selectionMode {
                HStack(spacing: 8) {
                    Text(selectedIds.isEmpty ? "选择两个方法进行合并" : "已选择 \(selectedIds.count) 个方法")
                        .font(.system(size: 12)).foregroundStyle(palette.gray600)
                    Spacer(minLength: 0)
                    ToolbarButton(title: "合并", icon: "arrow.triangle.merge", kind: .primary, disabled: selectedIds.count != 2 || saving) {
                        mergeItems = selectedIds.compactMap { id in items.first { $0.id == id } }
                    }
                    RoundIconButton(systemName: Ic.close, size: 28, title: "退出选择") { selectionMode = false; selectedIds = [] }
                }
                .padding(10).liquidInset(cornerRadius: 14).padding(.horizontal, 10).padding(.bottom, 6)
            }
            contentArea.mask { ScrollTitleFade() }
        }
        .liquidPanel()
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("方法索引").font(.system(size: 22, weight: .medium)).foregroundStyle(palette.gray900)
            }
            .frame(width: 118, alignment: .leading)
            PillIconMenu(title: "排序方法", icon: "arrow.up.arrow.down", selection: $sortMode,
                options: [("name", "首字母（A–Z）"), ("recent", "最近添加（新到旧）")], active: sortMode == "name")
            Spacer(minLength: 0)
            PillSearchField(text: $query, prompt: "搜索方法名称...") {
                Task { await load() }
            }

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
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
                    Text(query.isEmpty && categoryFilter.isEmpty ? "暂无方法索引" : "没有符合条件的方法").font(.system(size: 16.5)).foregroundStyle(palette.gray600)
                    Text(query.isEmpty && categoryFilter.isEmpty ? "上传并分析论文后，方法实体将自动归集于此" : "调整关键词或方法分组后重新搜索").font(.system(size: 13)).foregroundStyle(palette.gray500)
                }
                .frame(maxWidth: .infinity, minHeight: 380)
                .padding(.top, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    ForEach(filteredItems) { item in
                        MethodCard(item: item, groupName: groups.first { $0.id == item.category }?.name ?? MethodCategory.label(item.category), selected: selectedIds.contains(item.id), selectionMode: selectionMode,
                            editing: editingId == item.id, saving: saving,
                            onToggle: { toggleSelection(item.id) }, onEdit: { editingId = item.id },
                            onDelete: { deletingItem = item },
                            onSave: { name, definition in Task { await save(item, name: name, definition: definition) } },
                            onCancel: { editingId = nil },
                            dragIds: selectedIds.contains(item.id) ? selectedIds : [item.id])
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: MethodIndexItem
    let groupName: String
    let selected: Bool
    let selectionMode: Bool
    let editing: Bool
    let saving: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSave: (String, String) -> Void
    let onCancel: () -> Void
    var dragIds: [String] = []

    @State private var expanded = false
    @State private var draftName = ""
    @State private var draftDefinition = ""

    private var categoryColor: Color { MethodCategory.color(item.category, dark: palette.dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editing {
                WorkspaceItemEditor(name: $draftName, namePrompt: "方法名称", detail: $draftDefinition,
                                    detailPrompt: "方法说明", busy: saving, onSave: save, onCancel: onCancel)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(categoryColor).frame(width: 8, height: 8)
                    Text(item.name).font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(palette.gray800)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                if !item.definitionZh.isEmpty {
                    Text(item.definitionZh).font(.system(size: 14)).lineSpacing(4)
                        .foregroundStyle(palette.gray600).padding(.leading, 16)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Text(groupName).font(.system(size: 11))
                    .foregroundStyle(categoryColor).padding(.horizontal, 7).padding(.vertical, 4)
                    .liquidInset(cornerRadius: CornerRadius.chip, tint: categoryColor.opacity(0.08))
                Spacer(minLength: 0)
                Text("\(item.papers.count) 篇论文").font(.system(size: 11)).foregroundStyle(palette.gray500)
            }
            if expanded && !editing {
                VStack(spacing: 4) {
                    ForEach(item.papers, id: \.paperId) { paper in
                        Button { router.go(.reader(paperId: paper.paperId)) } label: {
                            HStack(spacing: 8) {
                                Text(paper.title).font(.system(size: 12.5)).lineLimit(1)
                                Spacer(minLength: 0)
                                Text("\(paper.blockIds.count) 处").font(.system(size: 10))
                            }
                            .foregroundStyle(palette.accent).padding(.horizontal, 8).frame(minHeight: 34)
                            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: CornerRadius.chip))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(17).frame(minHeight: 142, alignment: .topLeading)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidPanel(tint: selected || editing ? palette.accentFaint : nil)
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(selected || editing ? palette.accent.opacity(0.6) : .clear)
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .onTapGesture {
            guard !editing else { return }
            if selectionMode { onToggle() }
            else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() } }
        }
        #if os(macOS)
        .workspaceDraggable(kind: .methods, ids: dragIds, title: item.name, subtitle: groupName, enabled: !editing, palette: palette, dragHeight: expanded ? 80 : nil) {
            if selectionMode { onToggle() }
            else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() } }
        }
        #endif
        .contextMenu {
            Button(selected ? "取消选择" : "多选", systemImage: selected ? Ic.checkSquare : Ic.square, action: onToggle)
                .disabled(editing)
            Button("编辑条目", systemImage: Ic.pencil, action: onEdit).disabled(editing)
            Button("删除条目", systemImage: Ic.trash, role: .destructive, action: onDelete).disabled(editing)
        }
        .onChange(of: editing) { _, active in
            if active { draftName = item.name; draftDefinition = item.definitionZh }
        }
    }

    private func save() {
        guard !saving, !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSave(draftName, draftDefinition)
    }
}

private struct MethodMergePanel: View {
    @Environment(\.palette) private var palette
    let items: [MethodIndexItem]
    let saving: Bool
    let onCancel: () -> Void
    let onConfirm: (String, String, String) -> Void
    @State private var choice = "first"
    @State private var name = ""
    @State private var definition = ""
    @FocusState private var panelFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("合并方法").font(.system(size: 22, weight: .medium)).foregroundStyle(palette.gray900)
                Spacer(minLength: 0)
                RoundIconButton(systemName: Ic.close, size: 30, title: "取消合并", action: onCancel)
                    .disabled(saving)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.accent).frame(width: 24, height: 24)
                                .background(palette.accentSoft, in: Circle())
                            Text(item.name).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.gray700).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SlidingChoice(selection: $choice, options: [("first", "保留第一个"), ("second", "保留第二个"), ("custom", "重新编写")])
                    TextField("合并后的名称", text: $name, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 17, weight: .medium)).lineLimit(1...4)
                        .padding(11).liquidInset(cornerRadius: 12)
                        .accessibilityLabel("合并后的名称")
                    TextField("合并后的说明", text: $definition, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(4...12)
                        .padding(11).liquidInset(cornerRadius: 12)
                        .accessibilityLabel("合并后的说明")
                    Text("两条方法的论文来源和段落定位会一并保留。")
                        .font(.system(size: 12)).foregroundStyle(palette.gray500)
                }
            }.scrollIndicators(.hidden)
            HStack {
                ToolbarButton(title: "取消", disabled: saving, action: onCancel)
                Spacer(minLength: 0)
                ToolbarButton(title: "合并", icon: "arrow.triangle.merge", kind: .primary, busy: saving,
                              disabled: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    guard items.count == 2 else { return }
                    onConfirm(items[choice == "second" ? 1 : 0].id, name, definition)
                }
            }
        }
        .padding(20).liquidPanel(cornerRadius: 22).environment(\.floatingSurface, true)
        .focusable().focusEffectDisabled().focused($panelFocused)
        .onAppear { applyChoice(); panelFocused = true }
        .onChange(of: choice) { _, _ in applyChoice() }
        .onExitCommand { if !saving { onCancel() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("合并方法面板")
    }

    private func applyChoice() {
        guard items.count == 2 else { return }
        if choice == "custom" { name = ""; definition = "" }
        else {
            let item = items[choice == "second" ? 1 : 0]
            name = item.name; definition = item.definitionZh
        }
    }
}
