import SwiftUI
import UniformTypeIdentifiers

/// Mirrors projects/LibraryPage.tsx: project sidebar, toolbar, selection bar,
/// paper card grid, upload sheet, drag-to-project on desktop.
/// 窄窗口沿用桌面侧栏轨道，展开后点击空白收回。
struct LibraryPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(ProjectsStore.self) private var projectsStore
    @Environment(PapersStore.self) private var papersStore
    @Environment(AppServices.self) private var services
    @Environment(Router.self) private var router
    @Environment(\.openWindow) private var openWindow

    @State private var showNewProject = false
    @State private var projectSidebarCollapsed = false
    @State private var temporarilyExpanded = false
    @State private var newProjectName = ""
    @State private var searchQuery = ""
    @State private var showUpload = false
    @State private var uploading = false
    @State private var uploadError = ""
    @State private var selectionMode = false
    @State private var selectedIds: Set<String> = []
    @State private var statusFilter = "all"
    @State private var sortMode = "recent"
    @State private var targetProjectId = ""
    @State private var moving = false
    @State private var deleting = false
    @State private var actionError = ""
    @State private var renamingProjectId: String?
    @State private var renamingProjectName = ""
    @State private var renamingPaperId: String?
    @State private var renamingPaperTitle = ""
    @State private var paperPendingDelete: PaperListItem?
    @State private var projectPendingDelete: ProjectGroup?
    @State private var showBatchDeleteConfirm = false
    @State private var showFileImporter = false

    private var isCompact: Bool { containerWidth < LayoutBreakpoint.workspace }
    private var sidebarCollapsed: Bool { isCompact ? !temporarilyExpanded : projectSidebarCollapsed }

    // MARK: derived data

    private var visiblePapers: [PaperListItem] {
        var list = statusFilter == "all" ? papersStore.papers : papersStore.papers.filter { $0.status == statusFilter }
        list.sort { a, b in
            switch sortMode {
            case "title": return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            case "year": return (b.year ?? 0) < (a.year ?? 0)
            case "status": return statusLabel(a).compare(statusLabel(b)) == .orderedAscending
            default: return b.createdAt > a.createdAt
            }
        }
        return list
    }

    private func statusLabel(_ paper: PaperListItem) -> String {
        paper.statusEnum.label == "未知" ? paper.status : paper.statusEnum.label
    }

    private var hasActivePapers: Bool {
        papersStore.papers.contains { $0.statusEnum.isActive }
    }

    private var pipelineReady: Bool {
        services.pipeline.isConfigured
    }

    private var totalProjectPapers: Int {
        projectsStore.projects.reduce(0) { $0 + $1.paperCount }
    }

    // MARK: body

    var body: some View {
        WorkspaceSplitLayout(compact: isCompact, collapsed: projectSidebarCollapsed, temporarilyExpanded: $temporarilyExpanded) {
            sidebar
        } content: {
            mainColumn
        }
        .task { await projectsStore.fetch(); await papersStore.fetch(); await pollLoop() }
        .sheet(isPresented: $showUpload) { uploadSheet.presentationDetents([.medium]) }
        .alert("删除论文", isPresented: .init(get: { paperPendingDelete != nil }, set: { if !$0 { paperPendingDelete = nil } })) {
            Button("取消", role: .cancel) { paperPendingDelete = nil }
            Button("删除", role: .destructive) { if let paper = paperPendingDelete { Task { await deletePaper(paper) } } }
        } message: {
            Text("论文将移入回收站，PDF、解析结果、对话与笔记均可恢复。")
        }
        .alert("删除项目", isPresented: .init(get: { projectPendingDelete != nil }, set: { if !$0 { projectPendingDelete = nil } })) {
            Button("取消", role: .cancel) { projectPendingDelete = nil }
            Button("删除", role: .destructive) { if let project = projectPendingDelete { Task { await deleteProject(project) } } }
        } message: {
            Text(projectPendingDelete.map { "确定删除项目「\($0.name)」?项目内的论文不会被删除，只会移出该分组。" } ?? "")
        }
        .alert("批量删除", isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await batchDelete() } }
        } message: {
            Text("确定删除选中的 \(selectedIds.count) 篇论文？论文及对应的数据会保留在回收站中。")
        }
    }

    // MARK: polling (4s while any paper is processing)

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            if hasActivePapers {
                await papersStore.fetch()
            }
        }
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                if !sidebarCollapsed {
                    Text("项目分组")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.gray800)
                        .transition(.identity)
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if !sidebarCollapsed {
                        RoundIconButton(systemName: Ic.plus, size: 30, title: "新建项目") {
                            withAnimation(.easeInOut(duration: 0.15)) { showNewProject = true }
                        }
                        .tint(palette.accent)
                        .transition(.identity)
                    }
                    RoundIconButton(
                        systemName: Ic.panelLeft,
                        size: 30,
                        title: sidebarCollapsed ? "展开项目分组" : "收起项目分组",
                        animatesSymbolChange: false
                    ) {
                        if isCompact {
                            temporarilyExpanded.toggle()
                        } else {
                            withAnimation(.easeInOut(duration: 0.18)) { projectSidebarCollapsed.toggle() }
                            if projectSidebarCollapsed { showNewProject = false }
                        }
                    }
                }
            }
            .padding(.horizontal, sidebarCollapsed ? 11 : 15)
            .frame(minHeight: 50)

            if !sidebarCollapsed && showNewProject {
                newProjectForm
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(.identity)
            }

            if !sidebarCollapsed {
                ScrollView {
                    VStack(spacing: 2) {
                        allPapersRow
                        ForEach(projectsStore.projects) { project in
                            projectRow(project)
                        }
                    }
                    .padding(8)
                }
                .transition(.identity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .clipped()
        .liquidPanel()
    }

    private var newProjectForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image.ic(Ic.folderPlus).font(.system(size: 12)).foregroundStyle(palette.accent)
                Text("新建项目").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.gray700)
            }
            TextField("项目名称", text: $newProjectName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 36)
                .liquidInset(cornerRadius: CornerRadius.inset)
                .onSubmit { Task { await createProject() } }
            HStack(spacing: 6) {
                Button {
                    Task { await createProject() }
                } label: {
                    HStack(spacing: 5) {
                        Image.ic(Ic.check).font(.system(size: 11))
                        Text("创建")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.accentForeground)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).fill(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty ? palette.accent.opacity(0.42) : palette.accent))
                }
                .buttonStyle(.plain)
                .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showNewProject = false }
                    newProjectName = ""
                } label: {
                    Text("取消")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.gray600)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .liquidInset(cornerRadius: CornerRadius.inset)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .liquidInset(tint: palette.accentFaint)
    }

    private var allPapersRow: some View {
        Button {
            filterByProject(nil)
        } label: {
            HStack {
                Text("全部论文").font(.system(size: 14)).foregroundStyle(papersStore.filter.projectId == nil ? palette.accent : palette.gray700)
                Spacer(minLength: 0)
                Text("\(papersStore.filter.projectId == nil ? papersStore.papers.count : totalProjectPapers)")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.gray500.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).fill(papersStore.filter.projectId == nil ? palette.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func projectRow(_ project: ProjectGroup) -> some View {
        Group {
            if renamingProjectId == project.id {
                VStack(spacing: 5) {
                    TextField("项目名称", text: $renamingProjectName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                        .liquidInset(cornerRadius: CornerRadius.chip)
                        .overlay(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous).stroke(palette.accent))
                        .onSubmit { Task { await confirmRenameProject() } }
                    HStack(spacing: 4) {
                        Button { Task { await confirmRenameProject() } } label: {
                            Image.ic(Ic.check).font(.system(size: 11)).foregroundStyle(palette.accentForeground)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous).fill(palette.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(renamingProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button { cancelRenameProject() } label: {
                            Image.ic(Ic.close).font(.system(size: 11)).foregroundStyle(palette.gray600)
                                .frame(width: 26, height: 26)
                                .liquidInset(cornerRadius: CornerRadius.chip)
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            } else {
                Button {
                    filterByProject(project.id)
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(project.colorTag.isEmpty ? palette.accent : (Color(hex: project.colorTag) ?? palette.accent))
                            .frame(width: 7, height: 7)
                        Text(project.name)
                            .font(.system(size: 14))
                            .foregroundStyle(papersStore.filter.projectId == project.id ? palette.accent : palette.gray700)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(project.paperCount)")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.gray500.opacity(0.6))
                        HStack(spacing: 2) {
                            Button {
                                renamingProjectId = project.id
                                renamingProjectName = project.name
                            } label: {
                                Image.ic(Ic.pencil).font(.system(size: 10)).foregroundStyle(palette.gray400)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help("重命名")
                            Button {
                                projectPendingDelete = project
                            } label: {
                                Image.ic(Ic.trash).font(.system(size: 10)).foregroundStyle(palette.gray400)
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.plain)
                            .help("删除分组")
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 42)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).fill(papersStore.filter.projectId == project.id ? palette.accentSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onDrop(of: [.text], delegate: ProjectDropDelegate { ids in
                    Task { await move(ids: ids, projectId: project.id) }
                })
                #endif
            }
        }
    }

    // MARK: main column

    private var mainColumn: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 8) {
                ToolbarButton(title: "上传论文", icon: Ic.upload, kind: .primary) {
                    openUpload()
                }
                PillIconButton(title: selectionMode ? "退出选择" : "选择论文", icon: Ic.cursor, active: selectionMode) {
                    withAnimation(.smooth(duration: 0.24)) {
                        selectionMode.toggle()
                        if !selectionMode { selectedIds = [] }
                    }
                }
                Text("\(papersStore.papers.count) 篇论文")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if containerWidth < 620 {
                    PillIconButton(title: "处理任务", icon: "list.bullet.rectangle") { openWindow(id: "library-tasks") }
                    PillIconButton(title: "回收站", icon: Ic.trash) { openWindow(id: "library-trash") }
                } else {
                ToolbarButton(title: "处理任务", icon: "list.bullet.rectangle") {
                    openWindow(id: "library-tasks")
                }
                ToolbarButton(title: "回收站", icon: Ic.trash) {
                    openWindow(id: "library-trash")
                }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if selectionMode || !selectedIds.isEmpty {
                selectionBar
            }
            contentArea.mask { ScrollTitleFade() }
        }
        .liquidPanel()
    }

    private var toolbarTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LIBRARY").font(.system(size: 8, weight: .bold)).kerning(1.2).foregroundStyle(palette.accent)
            Text("论文库").font(.reading(22, weight: .medium)).foregroundStyle(palette.gray900)
        }
        .frame(width: 90, alignment: .leading)
    }

    private var libraryPickers: some View {
        HStack(spacing: 6) {
            PillIconMenu(title: "筛选论文状态", icon: Ic.listFilter, selection: $statusFilter, options: [
                ("all", "全部状态"),
                ("uploaded", "待解析"),
                ("ready", "已就绪"),
                ("parsed", "已解析"),
                ("normalizing", "清洗中"),
                ("analyzing", "分析中"),
                ("reducing", "归纳中"),
                ("parsing", "解析中"),
                ("error", "出错"),
            ], active: statusFilter != "all")

            PillIconMenu(title: "排序论文", icon: "arrow.up.arrow.down", selection: $sortMode, options: [
                ("recent", "最近添加"),
                ("title", "标题排序"),
                ("year", "年份排序"),
                ("status", "状态排序"),
            ], active: sortMode != "recent")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            toolbarTitle
            Spacer(minLength: 0)
            libraryPickers
            PillSearchField(text: $searchQuery, prompt: "搜索论文标题...", onSubmit: handleSearch)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
    }

    private func openUpload() {
        uploadError = ""
        showUpload = true
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { toggleSelectAll() } label: {
                    Label("选择当前结果", systemImage: allVisibleSelected ? Ic.checkSquare : Ic.square)
                        .font(.system(size: 12)).foregroundStyle(palette.accent)
                }.buttonStyle(.plain).noFocusRing()
                Text(selectedIds.isEmpty ? "点击论文进行选择" : "已选择 \(selectedIds.count) 篇")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                RoundIconButton(systemName: Ic.close, size: 24, title: "完成选择") { clearSelection() }
            }
            HStack(spacing: 8) {
                PillPicker(selection: $targetProjectId, options: [
                    ("", "移出项目分组"),
                ] + projectsStore.projects.map { ($0.id, "移动到：\($0.name)") }, maxWidth: 240)
                Spacer(minLength: 0)
                ToolbarButton(title: "移动", icon: Ic.folderInput, kind: .primary, busy: moving, disabled: selectedIds.isEmpty) {
                    Task { await move(ids: Array(selectedIds), projectId: targetProjectId.isEmpty ? nil : targetProjectId) }
                }
                ToolbarButton(title: "删除", icon: Ic.trash, kind: .danger, busy: deleting, disabled: selectedIds.isEmpty) {
                    showBatchDeleteConfirm = true
                }
            }
        }
        .padding(12)
        .liquidInset(cornerRadius: 16)
        .padding(.horizontal, 10).padding(.bottom, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var allVisibleSelected: Bool {
        let ids = visiblePapers.map(\.id)
        return !ids.isEmpty && ids.allSatisfy { selectedIds.contains($0) }
    }

    @ViewBuilder
    private var contentArea: some View {
        ScrollView {
            VStack(spacing: 10) {
                if (!papersStore.error.isEmpty || !actionError.isEmpty) && !papersStore.papers.isEmpty {
                    inlineError
                }
                if papersStore.loading && papersStore.papers.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        SkeletonCard(); SkeletonCard(); SkeletonCard()
                    }
                } else if !papersStore.error.isEmpty && papersStore.papers.isEmpty {
                    errorState
                } else if visiblePapers.isEmpty {
                    emptyState
                } else {
                    paperGrid
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var inlineError: some View {
        HStack(spacing: 8) {
            Image.ic(Ic.shieldAlert).font(.system(size: 13))
            Text(actionError.isEmpty ? papersStore.error : actionError)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                actionError = ""
                Task { await papersStore.fetch() }
            } label: {
                HStack(spacing: 5) {
                    Image.ic(Ic.refresh).font(.system(size: 12))
                    Text("重试")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.danger)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).stroke(palette.danger))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(palette.danger)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .liquidInset(tint: palette.danger.opacity(0.08))
    }

    private var errorState: some View {
        VStack(spacing: 8) {
            Image.ic(Ic.shieldAlert).font(.system(size: 40))
            Text("论文条目暂时无法载入").font(.system(size: 16.5)).foregroundStyle(palette.gray600)
            Text(papersStore.error).font(.system(size: 13)).foregroundStyle(palette.gray400).multilineTextAlignment(.center)
            Button {
                Task { await papersStore.fetch() }
            } label: {
                HStack(spacing: 5) {
                    Image.ic(Ic.refresh).font(.system(size: 13))
                    Text("重新载入")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).stroke(palette.gray500))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(palette.gray400)
        .frame(maxWidth: .infinity, minHeight: 380)
        .padding(.top, 40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image.ic(Ic.fileText)
                .font(.system(size: 44))
                .foregroundStyle(palette.gray400.opacity(0.3))
            Text("没有符合条件的论文").font(.system(size: 16.5)).foregroundStyle(palette.gray600)
            Text("调整筛选条件，或上传 PDF 开始阅读").font(.system(size: 13)).foregroundStyle(palette.gray500)
        }
        .frame(maxWidth: .infinity, minHeight: 380)
        .padding(.top, 40)
    }

    private var paperGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 12)], spacing: 12) {
            ForEach(visiblePapers) { paper in
                PaperCard(
                    paper: paper,
                    projectName: projectsStore.projects.first { $0.id == paper.projectId }?.name ?? "",
                    selected: selectedIds.contains(paper.id),
                    selectionMode: selectionMode,
                    renaming: renamingPaperId == paper.id,
                    renameValue: renamingPaperId == paper.id ? renamingPaperTitle : "",
                    onToggle: { toggleSelection(paper.id) },
                    onStartRename: {
                        renamingPaperId = paper.id
                        renamingPaperTitle = paper.displayTitle
                    },
                    onRenameChange: { renamingPaperTitle = $0 },
                    onConfirmRename: { Task { await confirmRenamePaper() } },
                    onCancelRename: { renamingPaperId = nil; renamingPaperTitle = "" },
                    onDelete: { paperPendingDelete = paper },
                    onClick: {
                        if selectionMode { toggleSelection(paper.id) }
                        else { router.go(.reader(paperId: paper.id)) }
                    },
                    dragIds: selectedIds.contains(paper.id) ? Array(selectedIds) : [paper.id]
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: actions

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func toggleSelectAll() {
        let ids = visiblePapers.map(\.id)
        if allVisibleSelected {
            ids.forEach { selectedIds.remove($0) }
        } else {
            ids.forEach { selectedIds.insert($0) }
        }
    }

    private func clearSelection() {
        selectedIds = []
        selectionMode = false
        targetProjectId = ""
    }

    private func filterByProject(_ projectId: String?) {
        var f = papersStore.filter
        f.projectId = projectId
        papersStore.setFilter(f)
        Task { await papersStore.fetch() }
        withAnimation(.easeInOut(duration: 0.18)) { temporarilyExpanded = false }
    }

    private func handleSearch() {
        var f = papersStore.filter
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        f.q = query.isEmpty ? nil : query
        papersStore.setFilter(f)
        Task { await papersStore.fetch() }
    }

    private func createProject() async {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do { _ = try await projectsStore.create(name: name) }
        catch { actionError = ApiFailure.wrap(error).localizedDescription; return }
        newProjectName = ""
        withAnimation(.easeInOut(duration: 0.15)) { showNewProject = false }
    }

    private func confirmRenameProject() async {
        let name = renamingProjectName.trimmingCharacters(in: .whitespaces)
        guard let id = renamingProjectId, !name.isEmpty else { return }
        do { try await projectsStore.renameProject(id: id, name: name) }
        catch { actionError = ApiFailure.wrap(error).localizedDescription; return }
        renamingProjectId = nil
        renamingProjectName = ""
    }

    private func cancelRenameProject() {
        renamingProjectId = nil
        renamingProjectName = ""
    }

    private func deleteProject(_ project: ProjectGroup) async {
        do { try await projectsStore.deleteProject(id: project.id) }
        catch { actionError = ApiFailure.wrap(error).localizedDescription; return }
        if papersStore.filter.projectId == project.id {
            filterByProject(nil)
        }
        projectPendingDelete = nil
    }

    private func confirmRenamePaper() async {
        let title = renamingPaperTitle.trimmingCharacters(in: .whitespaces)
        guard let id = renamingPaperId, !title.isEmpty else { return }
        do { try await papersStore.renamePaper(id: id, title: title) }
        catch { actionError = ApiFailure.wrap(error).localizedDescription; return }
        renamingPaperId = nil
        renamingPaperTitle = ""
    }

    private func deletePaper(_ paper: PaperListItem) async {
        do { try await papersStore.deletePaper(id: paper.id) }
        catch { actionError = ApiFailure.wrap(error).localizedDescription; return }
        selectedIds.remove(paper.id)
        await projectsStore.fetch()
        paperPendingDelete = nil
    }

    private func move(ids: [String], projectId: String?) async {
        guard !ids.isEmpty else { return }
        moving = true
        actionError = ""
        defer { moving = false }
        do {
            try await papersStore.movePapers(paperIds: ids, projectId: projectId)
            await projectsStore.fetch()
            clearSelection()
        } catch {
            actionError = ApiFailure.wrap(error).errorDescription ?? "移动论文失败，请重试。"
        }
    }

    private func batchDelete() async {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        deleting = true
        actionError = ""
        defer { deleting = false }
        for id in ids {
            do { try await papersStore.deletePaper(id: id) }
            catch { actionError = ApiFailure.wrap(error).localizedDescription; break }
        }
        await projectsStore.fetch()
        clearSelection()
    }

    // MARK: upload

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty, !uploading else { return }
            Task { await uploadFiles(urls) }
        case .failure(let error):
            let failure = error as NSError
            guard !(failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError) else { return }
            uploadError = "无法选择 PDF：\(error.localizedDescription)"
        }
    }

    private func uploadFiles(_ urls: [URL]) async {
        uploading = true
        uploadError = ""
        var failures: [String] = []
        defer { uploading = false }
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                // Read large PDFs away from the UI executor.
                let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                _ = try await papersStore.upload(fileData: data, fileName: url.lastPathComponent, projectId: papersStore.filter.projectId)
            } catch {
                failures.append("\(url.lastPathComponent)：\(ApiFailure.wrap(error).localizedDescription)")
            }
        }
        await papersStore.fetch()
        await projectsStore.fetch()
        uploadError = failures.joined(separator: "\n")
        if failures.isEmpty { showUpload = false }
    }

    private var uploadSheet: some View {
        VStack(spacing: 14) {
            HStack {
                Text("上传论文").font(.system(size: 15, weight: .medium)).foregroundStyle(palette.gray800)
                Spacer(minLength: 0)
                RoundIconButton(systemName: Ic.close, size: 28) { showUpload = false }
                    .disabled(uploading)
            }
            Button {
                showFileImporter = true
            } label: {
                VStack(spacing: 6) {
                    if uploading {
                        ProgressView().controlSize(.regular).frame(height: 28)
                    } else {
                        Image.ic(Ic.upload).font(.system(size: 22)).foregroundStyle(palette.gray500)
                        Text("点击选择 PDF 文件").font(.system(size: 14)).foregroundStyle(palette.gray600)
                        Text("支持多选批量上传").font(.system(size: 12)).foregroundStyle(palette.gray500.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .foregroundStyle(palette.gray300)
                )
            }
            .buttonStyle(.plain)
            .noFocusRing()
            .disabled(uploading)

            if !pipelineReady {
                HStack(alignment: .top, spacing: 8) {
                    Image.ic(Ic.fileText).font(.system(size: 14)).foregroundStyle(palette.gray500)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("可直接导入本地论文库").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.gray700)
                        Text("配置 AI 模型和 PDF 解析服务后，可在处理任务中开始解析。")
                            .font(.system(size: 11)).foregroundStyle(palette.gray500)
                    }
                    Spacer(minLength: 0)
                    Button {
                        showUpload = false
                        router.go(.settings)
                    } label: {
                        HStack(spacing: 4) {
                            Text("去设置")
                            Image.ic(Ic.arrowRight).font(.system(size: 10))
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    .noFocusRing()
                    .disabled(uploading)
                }
                .padding(12)
                .liquidInset(cornerRadius: CornerRadius.inset)
            }

            if !uploadError.isEmpty {
                Text(uploadError)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("导入到： \(projectsStore.projects.first { $0.id == papersStore.filter.projectId }?.name ?? "全部论文")")
                .font(.system(size: 12))
                .foregroundStyle(palette.gray500)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 384)
        .background(Color.clear)
        .interactiveDismissDisabled(uploading)
        // 文件面板必须由当前活动的 sheet 呈现;主页面已有 sheet 时无法再次呈现。
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
            handleImportResult($0)
        }
    }
}

// MARK: - Paper card

struct PaperCard: View {
    @Environment(\.palette) private var palette

    let paper: PaperListItem
    let projectName: String
    let selected: Bool
    let selectionMode: Bool
    let renaming: Bool
    let renameValue: String
    let onToggle: () -> Void
    let onStartRename: () -> Void
    let onRenameChange: (String) -> Void
    let onConfirmRename: () -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void
    let onClick: () -> Void

    @State private var hovered = false
    @State private var cornerHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                if renaming {
                    renameField
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(paper.displayTitle)
                            .font(.reading(16.5, weight: .medium))
                            .foregroundStyle(palette.gray800)
                            .fixedSize(horizontal: false, vertical: true)
                        if !paper.titleZh.isEmpty && paper.titleZh != paper.title {
                            Text(paper.titleZh)
                                .font(.system(size: 13.5))
                                .foregroundStyle(palette.gray500)
                                .padding(.top, 5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }


            }

            HStack(spacing: 8) {
                if let firstAuthor = paper.authors.first {
                    Text("\(firstAuthor)\(paper.authors.count > 1 ? " 等" : "")")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.gray500)
                        .lineLimit(1)
                }
                if let year = paper.year {
                    Text("\(year)").font(.system(size: 12)).foregroundStyle(palette.gray500)
                }
                if !projectName.isEmpty {
                    Text(projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.gray500)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .liquidInset(cornerRadius: ControlSpec.radius)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, paper.authors.isEmpty && paper.year == nil && projectName.isEmpty ? 0 : 13)

            Spacer(minLength: 11)
            HStack(alignment: .bottom, spacing: 12) {
                if !paper.domainTags.isEmpty {
                    FlowChips {
                        ForEach(paper.domainTags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous).fill(palette.accentSoft))
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    StatusDot(status: paper.statusEnum)
                    Text(paper.statusEnum.label == "未知" ? paper.status : paper.statusEnum.label)
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.gray500)
                .fixedSize()
                .padding(.vertical, 4)
            }
        }
        .frame(minHeight: 108, alignment: .topLeading)
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mask(CardCornerContentMask(active: cornerHovered && !renaming))
        .liquidPanel(tint: renaming || selected ? palette.accentFaint : nil)
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
            .stroke(renaming || selected ? palette.accent.opacity(0.6) : (hovered ? palette.gray300 : Color.clear)))
        .overlay(alignment: .topTrailing) {
            if !renaming {
                CardCornerActions(hovered: $cornerHovered) {
                    RoundIconButton(systemName: selected ? Ic.checkSquare : Ic.square, size: 30, title: selected ? "取消选择" : "选择", action: onToggle)
                    RoundIconButton(systemName: Ic.pencil, size: 30, title: "重命名", action: onStartRename)
                    RoundIconButton(systemName: Ic.trash, size: 30, title: "删除", action: onDelete)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous))
        .onHover { hovered = $0; if !$0 { cornerHovered = false } }
        .onTapGesture {
            if !renaming { onClick() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !renaming { onClick() } }
        .contextMenu {
            Button(selected ? "取消选择" : "选择", action: onToggle)
            Button("重命名", action: onStartRename)
            Button("删除", role: .destructive, action: onDelete)
        }
        #if os(macOS)
        .onDrag {
            NSItemProvider(object: dragIds.joined(separator: ",") as NSString)
        }
        #endif
    }

    /// Dragging a selected card drags the whole selection; otherwise just this card.
    var dragIds: [String] = []

    private var renameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("论文标题", text: Binding(get: { renameValue }, set: onRenameChange))
                .textFieldStyle(.plain)
                .font(.reading(15, weight: .medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .liquidInset(cornerRadius: CornerRadius.inset)
                .overlay(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).stroke(palette.accent))
                .onSubmit { onConfirmRename() }
            HStack(spacing: 5) {
                Button(action: onConfirmRename) {
                    HStack(spacing: 4) {
                        Image.ic(Ic.check).font(.system(size: 11))
                        Text("保存")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accentForeground)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).fill(palette.accent))
                }
                .buttonStyle(.plain)
                .disabled(renameValue.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(action: onCancelRename) {
                    HStack(spacing: 4) {
                        Image.ic(Ic.close).font(.system(size: 11))
                        Text("取消")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.gray600)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .liquidInset(cornerRadius: CornerRadius.inset)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#if os(macOS)
/// Decodes the paper-id list dragged from a card onto a project row.
struct ProjectDropDelegate: DropDelegate {
    let onDropIds: ([String]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String else { return }
            let ids = text.components(separatedBy: ",").filter { !$0.isEmpty }
            guard !ids.isEmpty else { return }
            Task { @MainActor in onDropIds(ids) }
        }
        return true
    }

    func dropEntered(info: DropInfo) {}
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}
#endif
