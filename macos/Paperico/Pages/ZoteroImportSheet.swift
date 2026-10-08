import SwiftUI
import UniformTypeIdentifiers

struct ZoteroImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PapersStore.self) private var papersStore
    @Environment(ProjectsStore.self) private var projectsStore
    @State private var folder: URL?
    @State private var selecting = false
    @State private var projectId = ""
    @State private var importing = false
    @State private var report: ZoteroImport.Report?
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从 Zotero 导出导入").font(.headline)
            Text("在 Zotero 中导出集合为 BibTeX，勾选 Export Files，再选择导出文件夹。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("选择文件夹") { selecting = true }.disabled(importing)
                Text(folder?.lastPathComponent ?? "尚未选择").lineLimit(1).foregroundStyle(.secondary)
            }
            Picker("导入到", selection: $projectId) {
                Text("全部论文").tag("")
                ForEach(projectsStore.projects) { Text($0.name).tag($0.id) }
            }.disabled(importing)
            if importing { ProgressView("正在导入…") }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            if let report {
                Text("已导入 \(report.imported.count) 篇，其中无元数据 \(report.withoutMetadata.count) 篇；重复跳过 \(report.duplicates.count) 项，未配对 \(report.unmatched.count) 项。")
                    .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.withoutMetadata, id: \.self) { Text("无元数据：" + $0) }
                        ForEach(report.duplicates, id: \.self) { Text("重复跳过：" + $0) }
                        ForEach(Array(report.unmatched.enumerated()), id: \.offset) { Text("未配对：" + $0.element) }
                        ForEach(report.failures, id: \.self) { Text("导入失败：" + $0).foregroundStyle(.red) }
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(importing)
                Button("导入") { Task { await run() } }.keyboardShortcut(.defaultAction).disabled(folder == nil || importing)
            }
        }.padding(24).frame(width: 540).interactiveDismissDisabled(importing)
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): folder = url; report = nil; error = ""
                case .failure(let failure):
                    let ns = failure as NSError
                    if ns.code != NSUserCancelledError { error = failure.localizedDescription }
                }
            }
    }

    private func run() async {
        guard let folder, !importing else { return }
        importing = true; error = ""; report = nil
        let secured = folder.startAccessingSecurityScopedResource()
        defer { importing = false; if secured { folder.stopAccessingSecurityScopedResource() } }
        do {
            report = try await papersStore.importZotero(folder: folder, projectId: projectId.isEmpty ? nil : projectId)
            await projectsStore.fetch()
        } catch { self.error = error.localizedDescription }
    }
}
