import SwiftUI
import UniformTypeIdentifiers

/// Mirrors projects/LibraryPage.tsx: project sidebar, toolbar, selection bar,
/// paper card grid, upload sheet, drag-to-project on desktop.
struct LibraryPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(ProjectsStore.self) private var projectsStore
    @Environment(PapersStore.self) private var papersStore
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(Router.self) private var router

    @State private var showNewProject = false
    @State private var projectSidebarCollapsed = false
    @State private var mobileSidebarOpen = false
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

    private var isCompact: Bool { sizeClass == .compact }
    private var sidebarCollapsed: Bool { projectSidebarCollapsed && !isCompact }

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
        guard let settings = settingsStore.settings else { return false }
        let llm = settings.modelProfiles.first?.apiKeyConfigured ?? false
        return llm && settings.mineru.apiKeyConfigured
    }

    private var totalProjectPapers: Int {
        projectsStore.projects.reduce(0) { $0 + $1.paperCount }
    }

    // MARK: body

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
        .task { await projectsStore.fetch(); await papersStore.fetch(); await pollLoop() }
        .sheet(isPresented: $showUpload) { uploadSheet.presentationDetents([.medium]) }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            handleImportResult(result)
        }
        .alert("删除论文", isPresented: .init(get: { paperPendingDelete != nil }, set: { if !$0 { paperPendingDelete = nil } })) {
            Button("取消", role: .cancel) { paperPendingDelete = nil }
            Button("删除", role: .destructive) { if let paper = paperPendingDelete { Task { await deletePaper(paper) } } }
        } message: {
            Text("确定删除这篇论文?")
        }
        .alert("删除项目", isPresented: .init(get: { projectPendingDelete != nil }, set: { if !$0 { projectPendingDelete = nil } })) {
            Button("取消", role: .cancel) { projectPendingDelete = nil }
            Button("删除", role: .destructive) { if let project = projectPendingDelete { Task { await deleteProject(project) } } }
        } message: {
            Text(projectPendingDelete.map { "确定删除项目「\($0.name)」?项目内的论文不会被删除,只会移出该分组。" } ?? "")
        }
        .alert("批量删除", isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await batchDelete() } }
        } message: {
            Text("确定删除选中的 \(selectedIds.count) 篇论文?此操作会同时删除对应的解析数据。")
        }
    }

    // MARK: polling (4s while any paper is processing)

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if hasActivePapers {
                await papersStore.fetch()
            }
        }
    }

    // MARK: compact chrome

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
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Color(hex: "#111419")!.opacity(0.38)
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = false } }
                sidebar
                    .frame(width: min(300, geo.size.width * 0.84))
                    .transition(.move(edge: .leading))
                    .padding(.vertical, 8)
                    .padding(.leading, 8)
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
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if !sidebarCollapsed {
                        RoundIconButton(systemName: Ic.folderPlus, size: 30, title: "新建项目") {
                            withAnimation(.easeInOut(duration: 0.15)) { showNewProject = true }
                        }
                        .tint(palette.accent)
                    }
                    RoundIconButton(
                        systemName: isCompact ? Ic.close : (sidebarCollapsed ? Ic.panelLeft : Ic.panelLeftClose),
                        size: 30,
                        title: isCompact ? "关闭项目分组" : (sidebarCollapsed ? "展开项目分组" : "收起项目分组")
                    ) {
                        if isCompact {
                            withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = false }
                        } else {
                            withAnimation(.easeInOut(duration: 0.18)) { projectSidebarCollapsed.toggle() }
                            if projectSidebarCollapsed { showNewProject = false }
                        }
                    }
                }
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 50)

            if !sidebarCollapsed && showNewProject {
                newProjectForm
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
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
            } else {
                Spacer(minLength: 0)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.gray0))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.gray300.opacity(0.68)))
        .shadow(color: palette.shadowCard, radius: 8, y: 3)
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
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.gray300))
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
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty ? palette.accent.opacity(0.42) : palette.accent))
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
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.gray0))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.gray200))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.accentFaint))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.accent.opacity(0.2)))
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
            .background(RoundedRectangle(cornerRadius: 8).fill(papersStore.filter.projectId == nil ? palette.accentSoft : Color.clear))
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
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.gray0))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.accent))
                        .onSubmit { Task { await confirmRenameProject() } }
                    HStack(spacing: 4) {
                        Button { Task { await confirmRenameProject() } } label: {
                            Image.ic(Ic.check).font(.system(size: 11)).foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6).fill(palette.accent))
                        }
                        .buttonStyle(.plain)
                        .disabled(renamingProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button { cancelRenameProject() } label: {
                            Image.ic(Ic.close).font(.system(size: 11)).foregroundStyle(palette.gray600)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 6).fill(palette.gray0))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.gray200))
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
                    .background(RoundedRectangle(cornerRadius: 8).fill(papersStore.filter.projectId == project.id ? palette.accentSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onDrop(of: [.text], delegate: ProjectDropDelegate(projectId: project.id) { ids in
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
            if selectionMode || !selectedIds.isEmpty {
                selectionBar
            }
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
                RoundIconButton(systemName: Ic.folderInput, size: 38, title: "项目分组") {
                    withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = true }
                }
            }
            if !isCompact {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LIBRARY").font(.mono(8, weight: .bold)).kerning(1.2).foregroundStyle(palette.accent)
                    Text("论文库").font(.reading(22, weight: .medium)).foregroundStyle(palette.gray900)
                }
                .frame(width: 118, alignment: .leading)
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Image.ic(Ic.search)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.gray400)
                        .padding(.leading, 8)
                    TextField("搜索论文标题...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5))
                        .padding(.leading, 5)
                        .padding(.trailing, 10)
                        .onSubmit { handleSearch() }
                }
                .frame(height: 38)
                .frame(maxWidth: 420)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray300))

                HStack(spacing: 6) {
                    Image.ic(Ic.listFilter).font(.system(size: 12)).foregroundStyle(palette.gray400)
                    Picker("", selection: $statusFilter) {
                        Text("全部状态").tag("all")
                        Text("待解析").tag("uploaded")
                        Text("已就绪").tag("ready")
                        Text("已解析").tag("parsed")
                        Text("清洗中").tag("normalizing")
                        Text("分析中").tag("analyzing")
                        Text("归纳中").tag("reducing")
                        Text("解析中").tag("parsing")
                        Text("出错").tag("error")
                    }
                    .labelsHidden()
                    .font(.system(size: 12))
                    .frame(width: 108)
                }
                .padding(.horizontal, 8)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray200))

                Picker("", selection: $sortMode) {
                    Text("最近添加").tag("recent")
                    Text("标题排序").tag("title")
                    Text("年份排序").tag("year")
                    Text("状态排序").tag("status")
                }
                .labelsHidden()
                .font(.system(size: 12))
                .frame(width: 106, height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray200))
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectionMode.toggle()
                    if !selectionMode { selectedIds = [] }
                }
            } label: {
                HStack(spacing: 6) {
                    Image.ic(Ic.cursor).font(.system(size: 12))
                    Text("选择")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selectionMode ? palette.accent : palette.gray600)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(selectionMode ? palette.accentSoft : palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(selectionMode ? palette.accent.opacity(0.34) : palette.gray200))
            }
            .buttonStyle(.plain)

            Button {
                if !pipelineReady {
                    uploadError = "上传前需要先配置并测试 AI 模型 API Key 与 MinerU Token。"
                    showUpload = true
                    return
                }
                uploadError = ""
                showUpload = true
            } label: {
                HStack(spacing: 6) {
                    Image.ic(Ic.upload).font(.system(size: 12))
                    Text("上传论文")
                }
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 50)
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Button { toggleSelectAll() } label: {
                HStack(spacing: 5) {
                    Image.ic(allVisibleSelected ? Ic.checkSquare : Ic.square).font(.system(size: 14))
                    Text("选择当前结果")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.accent)
            }
            .buttonStyle(.plain)

            Text(selectedIds.isEmpty ? "点击条目或复选框进行选择" : "已选择 \(selectedIds.count) 篇")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.gray700)

            Spacer(minLength: 0)

            Picker("", selection: $targetProjectId) {
                Text("移出项目分组").tag("")
                ForEach(projectsStore.projects) { project in
                    Text("移动到:\(project.name)").tag(project.id)
                }
            }
            .labelsHidden()
            .font(.system(size: 12))
            .frame(width: 190, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.gray0))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.gray200))

            Button {
                Task { await move(ids: Array(selectedIds), projectId: targetProjectId.isEmpty ? nil : targetProjectId) }
            } label: {
                HStack(spacing: 5) {
                    if moving { SpinnerIcon(size: 13) } else { Image.ic(Ic.folderInput).font(.system(size: 13)) }
                    Text("移动")
                }
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.accent))
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty || moving)

            Button {
                showBatchDeleteConfirm = true
            } label: {
                HStack(spacing: 5) {
                    if deleting { SpinnerIcon(size: 13) } else { Image.ic(Ic.trash).font(.system(size: 13)) }
                    Text("删除")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.danger)
                .padding(.horizontal, 9)
                .frame(minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.gray200))
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty || deleting)

            Button {
                clearSelection()
            } label: {
                Text("完成")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.gray600)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .background(palette.accentFaint.opacity(0.52))
        .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }
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
                .background(RoundedRectangle(cornerRadius: 8).stroke(palette.danger))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(palette.danger)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.danger.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.danger.opacity(0.22)))
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
                .background(RoundedRectangle(cornerRadius: 8).stroke(palette.gray500))
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
            Text("调整筛选条件,或上传 PDF 开始阅读").font(.system(size: 13)).foregroundStyle(palette.gray500)
        }
        .frame(maxWidth: .infinity, minHeight: 380)
        .padding(.top, 40)
    }

    private var paperGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
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
        withAnimation(.easeInOut(duration: 0.18)) { mobileSidebarOpen = false }
    }

    private func handleSearch() {
        var f = papersStore.filter
        f.q = searchQuery.isEmpty ? nil : searchQuery
        papersStore.setFilter(f)
        Task { await papersStore.fetch() }
    }

    private func createProject() async {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        try? await projectsStore.create(name: name)
        newProjectName = ""
        withAnimation(.easeInOut(duration: 0.15)) { showNewProject = false }
    }

    private func confirmRenameProject() async {
        let name = renamingProjectName.trimmingCharacters(in: .whitespaces)
        guard let id = renamingProjectId, !name.isEmpty else { return }
        try? await projectsStore.renameProject(id: id, name: name)
        renamingProjectId = nil
        renamingProjectName = ""
    }

    private func cancelRenameProject() {
        renamingProjectId = nil
        renamingProjectName = ""
    }

    private func deleteProject(_ project: ProjectGroup) async {
        try? await projectsStore.deleteProject(id: project.id)
        if papersStore.filter.projectId == project.id {
            filterByProject(nil)
        }
        projectPendingDelete = nil
    }

    private func confirmRenamePaper() async {
        let title = renamingPaperTitle.trimmingCharacters(in: .whitespaces)
        guard let id = renamingPaperId, !title.isEmpty else { return }
        try? await papersStore.renamePaper(id: id, title: title)
        renamingPaperId = nil
        renamingPaperTitle = ""
    }

    private func deletePaper(_ paper: PaperListItem) async {
        try? await papersStore.deletePaper(id: paper.id)
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
            actionError = ApiFailure.wrap(error).errorDescription ?? "移动论文失败,请重试。"
        }
    }

    private func batchDelete() async {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        deleting = true
        actionError = ""
        defer { deleting = false }
        for id in ids {
            try? await papersStore.deletePaper(id: id)
        }
        await projectsStore.fetch()
        clearSelection()
    }

    // MARK: upload

    private func handleImportResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        Task { await uploadFiles(urls) }
    }

    private func uploadFiles(_ urls: [URL]) async {
        uploading = true
        uploadError = ""
        var succeeded = false
        defer { uploading = false }
        do {
            for url in urls {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                _ = try await papersStore.upload(fileData: data, fileName: url.lastPathComponent, projectId: papersStore.filter.projectId)
            }
            await papersStore.fetch()
            succeeded = true
        } catch {
            uploadError = ApiFailure.wrap(error).errorDescription ?? "上传失败"
        }
        if succeeded { showUpload = false }
    }

    private var uploadSheet: some View {
        VStack(spacing: 14) {
            HStack {
                Text("上传论文").font(.system(size: 15, weight: .medium)).foregroundStyle(palette.gray800)
                Spacer(minLength: 0)
                RoundIconButton(systemName: Ic.close, size: 28) { showUpload = false }
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
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .foregroundStyle(palette.gray300)
                )
            }
            .buttonStyle(.plain)

            if !pipelineReady {
                HStack(alignment: .top, spacing: 8) {
                    Image.ic(Ic.shieldAlert).font(.system(size: 14)).foregroundStyle(palette.amber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("处理流程尚未配置").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.amber)
                        Text("需要模型 API Key 和 MinerU Token。").font(.system(size: 10)).foregroundStyle(palette.amber.opacity(0.85))
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
                        .foregroundStyle(palette.amber)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.amber.opacity(0.09)))
            }

            if !uploadError.isEmpty {
                Text(uploadError)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("当前项目: \(projectsStore.projects.first { $0.id == papersStore.filter.projectId }?.name ?? "未选择")")
                .font(.system(size: 12))
                .foregroundStyle(palette.gray500)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 384)
        .background(palette.gray0)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 9) {
                if showSelector {
                    Button(action: onToggle) {
                        Image.ic(selected ? Ic.checkSquare : Ic.square)
                            .font(.system(size: 15))
                            .foregroundStyle(selected ? palette.accent : palette.gray300)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(selected ? "取消选择" : "选择")
                }

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

                if !renaming {
                    HStack(spacing: 2) {
                        if hovered || selectionMode {
                            Image.ic(Ic.grip).font(.system(size: 13)).foregroundStyle(palette.gray300)
                            Button(action: onStartRename) {
                                Image.ic(Ic.pencil).font(.system(size: 12)).foregroundStyle(palette.gray400)
                                    .frame(width: 25, height: 25)
                            }
                            .buttonStyle(.plain)
                            .help("重命名")
                            Button(action: onDelete) {
                                Image.ic(Ic.trash).font(.system(size: 12)).foregroundStyle(palette.gray400)
                                    .frame(width: 25, height: 25)
                            }
                            .buttonStyle(.plain)
                            .help("删除")
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    StatusDot(status: paper.statusEnum)
                    Text(paper.statusEnum.label == "未知" ? paper.status : paper.statusEnum.label)
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.gray500)
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
                        .background(Capsule().fill(palette.gray50))
                        .overlay(Capsule().stroke(palette.gray200))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 13)

            if !paper.domainTags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(paper.domainTags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5).fill(palette.accentSoft))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 11)
            }
        }
        .padding(17)
        .frame(minHeight: 142, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor))
        .shadow(color: palette.shadowCard, radius: hovered ? 6 : 2, y: hovered ? 3 : 1)
        .offset(y: hovered && !renaming ? -1 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovered = $0 }
        .onTapGesture {
            if !renaming { onClick() }
        }
        #if os(macOS)
        .onDrag {
            NSItemProvider(object: dragIds.joined(separator: ",") as NSString)
        }
        #endif
    }

    /// Dragging a selected card drags the whole selection; otherwise just this card.
    var dragIds: [String] = []

    private var showSelector: Bool { selectionMode || selected || hovered }

    private var cardBackground: Color {
        if renaming { return palette.accentFaint.opacity(0.34) }
        if selected { return palette.accentFaint.opacity(0.42) }
        return palette.gray0
    }

    private var borderColor: Color {
        if renaming { return palette.accent.opacity(0.52) }
        if selected { return palette.accent.opacity(0.58) }
        if hovered { return palette.accent.opacity(0.42) }
        return palette.gray300.opacity(0.66)
    }

    private var renameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("论文标题", text: Binding(get: { renameValue }, set: onRenameChange))
                .textFieldStyle(.plain)
                .font(.reading(15, weight: .medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.accent))
                .onSubmit { onConfirmRename() }
            HStack(spacing: 5) {
                Button(action: onConfirmRename) {
                    HStack(spacing: 4) {
                        Image.ic(Ic.check).font(.system(size: 11))
                        Text("保存")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(palette.accent))
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
                    .background(RoundedRectangle(cornerRadius: 7).fill(palette.gray0))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.gray200))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#if os(macOS)
/// Decodes the paper-id list dragged from a card onto a project row.
struct ProjectDropDelegate: DropDelegate {
    let projectId: String
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
