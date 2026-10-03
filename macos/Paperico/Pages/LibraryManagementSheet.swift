import SwiftUI

/// Task and recovery operations read the entire library, independently of search/project filters.
struct LibraryManagementSheet: View {
    enum Section: String, CaseIterable { case tasks = "处理任务", trash = "回收站" }
    @Environment(AppServices.self) private var services
    var onClose: () -> Void
    @Environment(\.palette) private var palette
    @Environment(Router.self) private var router
    @Environment(PapersStore.self) private var papersStore
    @Environment(ProjectsStore.self) private var projectsStore
    let section: Section
    @Environment(\.openWindow) private var openWindow
    @State private var papers: [PaperListItem] = []
    @State private var trash: [TrashedPaper] = []
    @State private var error = ""
    @State private var busy: Set<String> = []

    private var tasks: [PaperListItem] {
        papers.filter { $0.status != "ready" || services.pipeline.isProcessing($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image.ic(section == .tasks ? "list.bullet.rectangle" : Ic.trash)
                    .font(.system(size: 19)).foregroundStyle(palette.accent)
                Text(section.rawValue).font(.system(size: 20, weight: .semibold))
                Spacer()
                RoundIconButton(systemName: Ic.close, size: 30, title: "关闭论文库管理", foreground: .primary) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(section == .tasks
                 ? "查看待处理与失败的论文，停止任务或重新开始。"
                 : "恢复论文时，原始 PDF、解析结果、对话与笔记会一同保留。")
                .font(.callout).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if section == .tasks && tasks.isEmpty {
                emptyState("当前没有待处理任务", symbol: "checkmark.circle")
            } else if section == .trash && trash.isEmpty {
                emptyState("回收站是空的", symbol: Ic.trash)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if section == .tasks {
                            ForEach(tasks) { paper in taskRow(paper).modifier(ManagementRowSurface()) }
                        } else {
                            ForEach(trash) { entry in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.paper.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                        Text("移入时间：\(String(entry.deletedAt.prefix(10)))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    ToolbarButton(title: "恢复", icon: "arrow.uturn.backward", busy: busy.contains(entry.id)) {
                                        perform(id: entry.id) { try await services.library.restorePaper(id: entry.id) }
                                    }
                                }.modifier(ManagementRowSurface())
                            }
                        }
                    }.padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidPanel(cornerRadius: 24)
        .environment(\.floatingSurface, true)
        .task {
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await refresh()
            }
        }
    }

    private func emptyState(_ title: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskRow(_ paper: PaperListItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.displayTitle).lineLimit(2)
                Text(paper.statusEnum.label).font(.caption).foregroundStyle(.secondary)
                if let progress = services.pipeline.progress[paper.id] {
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
                if !paper.errorMessage.isEmpty { Text(paper.errorMessage).font(.caption).foregroundStyle(.red).lineLimit(3) }
                if let failure = services.pipeline.failures[paper.id] { Text(failure).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            Button("打开") { onClose(); router.go(.reader(paperId: paper.id)); openWindow(id: "workspace") }.buttonStyle(LiquidActionButtonStyle())
            if services.pipeline.isProcessing(paper.id) {
                Button("停止") { perform(id: paper.id) { await services.pipeline.cancel(paperId: paper.id) } }
                    .buttonStyle(LiquidActionButtonStyle()).disabled(busy.contains(paper.id))
            } else {
                Menu(paper.status == "uploaded" ? "开始处理" : "重试") {
                    Button("重新解析 PDF") { services.pipeline.reparse(paperId: paper.id) }
                    Button("重新翻译已有段落") { services.pipeline.retranslate(paperId: paper.id) }
                    Button("恢复上次返回结果（不调用模型）") { services.pipeline.recoverAnalysis(paperId: paper.id) }
                }
            }
        }.padding(.vertical, 6)
    }

    private func refresh() async {
        if section == .tasks { papers = await services.library.listPapers() }
        else { trash = await services.library.listTrash() }
    }

    private func perform(id: String, operation: @escaping () async throws -> Void) {
        busy.insert(id)
        error = ""
        Task {
            defer { busy.remove(id) }
            do {
                try await operation()
                await refresh()
                await papersStore.fetch()
                await projectsStore.fetch()
            } catch { self.error = ApiFailure.wrap(error).localizedDescription }
        }
    }
}

private struct ManagementRowSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Separate singleton utility scenes keep task and trash windows independent.
struct LibraryManagementWindow: View {
    let section: LibraryManagementSheet.Section
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.palette) private var palette
    @Environment(\.backgroundOpacity) private var backgroundOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var windowId: String { section == .tasks ? "library-tasks" : "library-trash" }
    var body: some View {
        LibraryManagementSheet(onClose: { dismissWindow(id: windowId) }, section: section)
            .padding(12).frame(minWidth: 490, minHeight: 380)
            .onExitCommand { dismissWindow(id: windowId) }
            .onAppear { applyWindowChrome() }
            .onChange(of: palette.appBase) { _, _ in applyWindowChrome() }
            .onChange(of: backgroundOpacity) { _, _ in applyWindowChrome() }
            .onChange(of: reduceTransparency) { _, _ in applyWindowChrome() }
    }

    private func applyWindowChrome() {
        WindowChrome.applyToAll(baseColor: NSColor(palette.appBase), opacity: reduceTransparency ? 1 : backgroundOpacity)
    }
}
