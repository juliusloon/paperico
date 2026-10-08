import SwiftUI

struct ChatSourceCard: View {
    @Environment(\.dismiss) private var dismiss
    let source: ChatSourceRef
    let library: PaperLibrary
    let onOpen: () -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var error = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.isEmpty ? (source.title ?? "引用来源") : title).font(.headline).textSelection(.enabled)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if !loaded { ProgressView() }
            else { ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 280) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(source.kind == .method ? "打开方法索引" : (source.blockId == nil ? "打开论文" : "打开论文并定位"), action: onOpen)
                    .disabled(!loaded || !error.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520).task { await load() }
    }
    private func load() async {
        do {
            if source.kind == .method, let key = source.methodKey {
                guard let method = try await library.methodIndex().first(where: { $0.id == key }) else { throw AutomationError("方法已删除或不可用。") }
                title = method.name; text = method.definitionZh
            } else if let id = source.paperId {
                let detail = try await library.paperDetail(id: id, markOpened: false)
                title = detail.paper.displayTitle
                if let blockId = source.blockId {
                    guard let block = detail.blocks.first(where: { $0.id == blockId }) else { throw AutomationError("证据块已变化，请重新提问。") }
                    text = String([block.textOriginal, block.captionOriginal, block.latex, block.tableHtml].filter { !$0.isEmpty }.joined(separator: "\n").prefix(6000))
                } else {
                    text = [detail.paper.authors.joined(separator: ", "), detail.paper.year.map(String.init) ?? "", detail.paper.venue, detail.paper.tldr]
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                }
            }
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
}
