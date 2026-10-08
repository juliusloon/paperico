import SwiftUI

struct MetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
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
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑论文元数据").font(.headline)
            Form {
                TextField("标题", text: $title)
                TextField("作者（逗号分隔）", text: $authors)
                TextField("年份", text: $year)
                TextField("期刊 / 会议", text: $venue)
                TextField("DOI", text: $doi)
                TextField("arXiv ID", text: $arxiv)
            }.textFieldStyle(.roundedBorder).disabled(saving)
            Text("保存后标记为手动，自动识别与分析会保留这些信息。")
                .font(.caption).foregroundStyle(.secondary)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("保存") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(saving)
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
