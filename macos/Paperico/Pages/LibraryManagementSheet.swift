import SwiftUI

/// Task and recovery operations read the entire library, independently of search/project filters.
struct LibraryManagementSheet: View {
    enum Section: String, CaseIterable { case tasks = "处理任务", trash = "回收站", files = "未引用文件" }
    @Environment(AppServices.self) private var services
    var onClose: () -> Void
    @Environment(\.palette) private var palette
    @Environment(Router.self) private var router
    @Environment(PapersStore.self) private var papersStore
    @Environment(ProjectsStore.self) private var projectsStore
    let section: Section
    @State private var papers: [PaperListItem] = []
    @State private var trash: [TrashedPaper] = []
    @State private var orphans: [OrphanEntry] = []
    @State private var error = ""
    @State private var busy: Set<String> = []
    @State private var pendingDeleteId: String?
    /// 勾选 + 显式确认后才删除；孤儿文件默认一个都不选。
    @State private var selectedOrphans: Set<String> = []
    @State private var confirmOrphanDelete = false

    private var tasks: [PaperListItem] {
        papers.filter { $0.status != "ready" || services.pipeline.isProcessing($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image.ic(section == .tasks ? "list.bullet.rectangle" : section == .files ? "folder.badge.questionmark" : Ic.trash)
                    .font(.system(size: 19)).foregroundStyle(palette.accent)
                Text(section.rawValue).font(.system(size: 20, weight: .semibold))
                Spacer()
                RoundIconButton(systemName: Ic.close, size: 30, title: "关闭论文库管理", foreground: .primary) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(section == .tasks
                 ? "查看待处理与失败的论文，停止任务或重新开始。"
                 : section == .trash
                 ? "可恢复论文及其 PDF、解析结果、对话与笔记，也可永久删除。"
                 : "磁盘上存在、但论文索引里没有对应记录的文件。默认只报告，不会自动删除。")
                .font(.callout).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if section == .tasks && tasks.isEmpty {
                emptyState("当前没有待处理任务", symbol: "checkmark.circle")
            } else if section == .trash && trash.isEmpty {
                emptyState("回收站是空的", symbol: Ic.trash)
            } else if section == .files && orphans.isEmpty {
                emptyState("没有未引用的文件", symbol: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if section == .tasks {
                            ForEach(tasks) { paper in taskRow(paper).modifier(ManagementRowSurface()) }
                        } else if section == .trash {
                            ForEach(trash) { entry in
                                trashRow(entry).modifier(ManagementRowSurface())
                            }
                        } else {
                            orphanSection
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

    private func trashRow(_ entry: TrashedPaper) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.paper.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text("移入时间：\(String(entry.deletedAt.prefix(10)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("恢复") {
                    perform(id: entry.id) { try await services.library.restorePaper(id: entry.id) }
                }.buttonStyle(LiquidActionButtonStyle())
                Button("永久删除", role: .destructive) { pendingDeleteId = entry.id }
                    .buttonStyle(LiquidActionButtonStyle()).foregroundStyle(palette.danger)
            }
            .disabled(busy.contains(entry.id))
            if pendingDeleteId == entry.id {
                Text("将永久删除这篇论文的 PDF、解析结果、对话与笔记，无法恢复。")
                    .font(.callout).foregroundStyle(palette.danger)
                HStack {
                    Spacer()
                    Button("取消") { pendingDeleteId = nil }.buttonStyle(LiquidActionButtonStyle())
                    ToolbarButton(title: "确认永久删除", icon: Ic.trash, busy: busy.contains(entry.id)) {
                        perform(id: entry.id) {
                            await services.pipeline.cancel(paperId: entry.id)
                            try await services.library.permanentlyDeletePaper(id: entry.id)
                            pendingDeleteId = nil
                        }
                    }.foregroundStyle(palette.danger)
                }.disabled(busy.contains(entry.id))
            }
        }
    }

    /// 未引用文件：默认全部不勾选，删除需要"勾选 + 二次确认"两步。
    private var orphanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(orphans) { entry in
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { selectedOrphans.contains(entry.id) },
                        set: { on in
                            if on { selectedOrphans.insert(entry.id) } else { selectedOrphans.remove(entry.id) }
                            confirmOrphanDelete = false
                        }
                    )).labelsHidden().toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.path).font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text("\(Self.sizeLabel(entry.sizeBytes)) · \(Self.kindLabel(entry.kind))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .modifier(ManagementRowSurface())
            }
            if !selectedOrphans.isEmpty {
                HStack(spacing: 10) {
                    Text("已选择 \(selectedOrphans.count) 项")
                        .font(.callout).foregroundStyle(palette.danger)
                    Spacer()
                    Button("取消选择") { selectedOrphans.removeAll(); confirmOrphanDelete = false }
                        .buttonStyle(LiquidActionButtonStyle())
                    if confirmOrphanDelete {
                        ToolbarButton(title: "确认删除", icon: Ic.trash, busy: false) {
                            Task { await deleteSelectedOrphans() }
                        }.foregroundStyle(palette.danger)
                    } else {
                        Button("删除所选…") { confirmOrphanDelete = true }
                            .buttonStyle(LiquidActionButtonStyle()).foregroundStyle(palette.danger)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// 逐步删除：任一项失败就停下并保留记录，用户可重试（对齐永久删除的语义）。
    private func deleteSelectedOrphans() async {
        let targets = orphans.filter { selectedOrphans.contains($0.id) }
        guard !targets.isEmpty else { return }
        busy.insert("orphans")
        error = ""
        var failed: [String] = []
        for entry in targets {
            do { try await services.library.deleteOrphan(entry) }
            catch { failed.append("\(entry.path)：\(ApiFailure.wrap(error).localizedDescription)") }
        }
        busy.remove("orphans")
        if failed.isEmpty {
            selectedOrphans.removeAll()
            confirmOrphanDelete = false
        } else {
            error = "以下文件未能删除，可重试：\n" + failed.joined(separator: "\n")
        }
        await refresh()
    }

    private static func sizeLabel(_ bytes: Int64) -> String {
        bytes <= 0 ? "体积未知" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func kindLabel(_ kind: OrphanEntry.Kind) -> String {
        switch kind {
        case .paperDirectory: return "解析块 / 实体 / 对话"
        case .mineruOutput: return "MinerU 解析产物"
        case .analyses: return "模型原始响应"
        case .pdf: return "PDF"
        }
    }

    private func taskRow(_ paper: PaperListItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(paper.displayTitle).lineLimit(2)
                Text(services.pipeline.statusLabel(for: paper)).font(.caption).foregroundStyle(.secondary)
                if let progress = services.pipeline.progress[paper.id] {
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
                if !paper.errorMessage.isEmpty { Text(paper.errorMessage).font(.caption).foregroundStyle(.red).lineLimit(3) }
                if let failure = services.pipeline.failures[paper.id] { Text(failure).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            Button("打开") { onClose(); router.go(.reader(paperId: paper.id)) }.buttonStyle(LiquidActionButtonStyle())
            if services.pipeline.isProcessing(paper.id) {
                Button("停止") { perform(id: paper.id) { await services.pipeline.cancel(paperId: paper.id) } }
                    .buttonStyle(LiquidActionButtonStyle()).disabled(busy.contains(paper.id))
            } else {
                Menu {
                    Button("继续处理（复用已有结果）") { services.pipeline.startProcessing(paperId: paper.id) }
                    Button("重新解析 PDF") { services.pipeline.reparse(paperId: paper.id) }
                    Button("重新翻译已有段落") { services.pipeline.retranslate(paperId: paper.id) }
                    Button("恢复上次返回结果（不调用模型）") { services.pipeline.recoverAnalysis(paperId: paper.id) }
                } label: {
                    HStack(spacing: 5) {
                        Text(paper.status == "uploaded" ? "开始处理" : "重试")
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .tint(palette.gray800).foregroundStyle(palette.gray800)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .fixedSize().noFocusRing()
                .liquidTool().disabled(busy.contains(paper.id))
            }
        }.padding(.vertical, 6)
    }

    private func refresh() async {
        switch section {
        case .tasks: papers = await services.library.listPapers()
        case .trash: trash = await services.library.listTrash()
        case .files:
            orphans = await services.library.orphanFiles()
            // 报告刷新后，勾选项必须仍然存在，否则"确认删除"会作用在错的条目上。
            selectedOrphans.formIntersection(Set(orphans.map(\.id)))
            if selectedOrphans.isEmpty { confirmOrphanDelete = false }
        }
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

/// A modal block in the workspace's existing view tree; it never creates a window.
struct LibraryManagementOverlay: View {
    let section: LibraryManagementSheet.Section
    let onClose: () -> Void
    @Environment(\.palette) private var palette
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                OutsideDismissArea(label: "关闭论文库管理", dimOpacity: palette.dark ? 0.3 : 0.15, action: onClose)
                LibraryManagementSheet(onClose: onClose, section: section)
                    .id(section)
                    .frame(width: min(760, max(0, geometry.size.width - 40)),
                           height: min(600, max(0, geometry.size.height - 80)))
                    .shadow(color: .black.opacity(0.16), radius: 24, y: 12)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onExitCommand(perform: onClose)
    }
}
