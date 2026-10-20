import SwiftUI

struct MetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    let onSave: (PaperMetadata.Metadata) async throws -> Void
    @State private var title: String
    @State private var authors: String
    @State private var year: String
    @State private var venue: String
    @State private var doi: String
    @State private var arxiv: String
    @State private var saving = false
    @State private var error = ""

    init(paper: PaperListItem, onSave: @escaping (PaperMetadata.Metadata) async throws -> Void) {
        self.onSave = onSave
        _title = State(initialValue: paper.displayTitle)
        _authors = State(initialValue: paper.authors.joined(separator: ", "))
        _year = State(initialValue: paper.year.map(String.init) ?? "")
        _venue = State(initialValue: paper.venue)
        _doi = State(initialValue: paper.doi ?? "")
        _arxiv = State(initialValue: paper.arxivId ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SheetSpec.spacing) {
            Text("编辑论文元数据").font(SheetSpec.titleFont).foregroundStyle(palette.gray900)
            VStack(spacing: 10) {
                field("标题", text: $title, placeholder: "论文标题")
                field("作者", text: $authors, placeholder: "多位作者以逗号分隔")
                field("年份", text: $year, placeholder: "出版年份（可选）")
                field("期刊 / 会议", text: $venue, placeholder: "期刊或会议名称（可选）")
                field("DOI", text: $doi, placeholder: "DOI（可选）")
                field("arXiv ID", text: $arxiv, placeholder: "arXiv ID（可选）")
            }.disabled(saving)
            Text("保存后标记为手动，自动识别与分析会保留这些信息。")
                .font(SheetSpec.captionFont).foregroundStyle(palette.gray500)
                .fixedSize(horizontal: false, vertical: true)
            if !error.isEmpty {
                Text(error).font(SheetSpec.captionFont).foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer()
                ToolbarButton(title: "取消", disabled: saving) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ToolbarButton(title: "保存", kind: .primary, busy: saving,
                              disabled: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Task { await save() }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(palette.gray800)
        .padding(SheetSpec.padding)
        .frame(width: SheetSpec.width(preferred: 520, containerWidth: containerWidth))
        .interactiveDismissDisabled(saving)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 12) {
            Text(label).font(SheetSpec.bodyFont).foregroundStyle(palette.gray600)
                .frame(width: 82, alignment: .leading)
            FormTextField(text: text, placeholder: placeholder)
                .accessibilityLabel(label)
        }
    }

    private func save() async {
        let trimmedYear = year.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedYear.isEmpty || (Int(trimmedYear).map { (1...9999).contains($0) } ?? false) else {
            error = "请输入有效年份，或留空。"; return
        }
        saving = true
        defer { saving = false }
        do {
            try await onSave(.init(title: title, authors: authors.components(separatedBy: CharacterSet(charactersIn: ",，")),
                                   year: Int(trimmedYear), venue: venue, doi: doi, arxivId: arxiv))
            dismiss()
        } catch { self.error = ApiFailure.wrap(error).localizedDescription }
    }
}
