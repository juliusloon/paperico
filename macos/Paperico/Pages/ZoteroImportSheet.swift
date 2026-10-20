import SwiftUI
import UniformTypeIdentifiers

struct ZoteroImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(PapersStore.self) private var papersStore
    @Environment(ProjectsStore.self) private var projectsStore
    @State private var folder: URL?
    @State private var selecting = false
    @State private var projectId = ""
    @State private var importing = false
    @State private var report: ZoteroImport.Report?
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SheetSpec.spacing) {
            Text("从 Zotero 导入").font(SheetSpec.titleFont).foregroundStyle(palette.gray900)
            Text("在 Zotero 中导出集合为 BibTeX，勾选 Export Files，再选择导出文件夹。")
                .font(SheetSpec.bodyFont).foregroundStyle(palette.gray500)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ToolbarButton(title: "选择文件夹", icon: "folder", disabled: importing) { selecting = true }
                Text(folder?.lastPathComponent ?? "尚未选择文件夹")
                    .font(SheetSpec.bodyFont).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(palette.gray600)
                    .help(folder?.lastPathComponent ?? "尚未选择文件夹")
            }
            HStack(spacing: 12) {
                Text("导入到").font(SheetSpec.bodyFont).foregroundStyle(palette.gray600)
                PillPicker(selection: $projectId, options: [("", "全部论文")] + projectsStore.projects.map { ($0.id, $0.name) }, disabled: importing)
                    .accessibilityLabel("导入到")
            }
            if importing { ProgressView("正在导入…").font(SheetSpec.bodyFont).controlSize(.small) }
            if !error.isEmpty {
                Text(error).foregroundStyle(palette.danger).font(SheetSpec.captionFont)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let report {
                Text("已导入 \(report.imported.count) 篇，其中无元数据 \(report.withoutMetadata.count) 篇；重复跳过 \(report.duplicates.count) 项，未配对 \(report.unmatched.count) 项。")
                    .font(SheetSpec.bodyFont).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.withoutMetadata, id: \.self) { Text("无元数据：" + $0) }
                        ForEach(report.duplicates, id: \.self) { Text("重复跳过：" + $0) }
                        ForEach(Array(report.unmatched.enumerated()), id: \.offset) { Text("未配对：" + $0.element) }
                        ForEach(report.failures, id: \.self) { Text("导入失败：" + $0).foregroundStyle(palette.danger) }
                    }.font(SheetSpec.captionFont).foregroundStyle(palette.gray600)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 220)
            }
            HStack(spacing: 8) {
                Spacer()
                ToolbarButton(title: "关闭", disabled: importing) { dismiss() }.keyboardShortcut(.cancelAction)
                ToolbarButton(title: "导入", kind: .primary, busy: importing, disabled: folder == nil) {
                    Task { await run() }
                }.keyboardShortcut(.defaultAction)
            }
        }.foregroundStyle(palette.gray800)
            .padding(SheetSpec.padding)
            .frame(width: SheetSpec.width(preferred: 540, containerWidth: containerWidth))
            .interactiveDismissDisabled(importing)
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
