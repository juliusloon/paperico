import SwiftUI

struct ChatSourceCard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    let source: ChatSourceRef
    let library: PaperLibrary
    let onOpen: () -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var error = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: SheetSpec.spacing) {
            Text("引用来源").font(SheetSpec.titleFont).foregroundStyle(palette.gray900)
            if !loaded && error.isEmpty {
                ProgressView("正在读取来源…").font(SheetSpec.bodyFont).controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title.isEmpty ? (source.title ?? "引用来源") : title)
                            .font(SheetSpec.bodyFont.weight(.semibold)).foregroundStyle(palette.gray800)
                        if !error.isEmpty {
                            Text(error).font(SheetSpec.captionFont).foregroundStyle(palette.danger)
                        } else {
                            Text(text).font(SheetSpec.bodyFont).lineSpacing(4).foregroundStyle(palette.gray600)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 320)
            }
            HStack(spacing: 8) {
                Spacer()
                ToolbarButton(title: "关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                ToolbarButton(title: source.kind == .method ? "打开方法索引" : (source.blockId == nil ? "打开论文" : "打开论文并定位"),
                              kind: .primary, disabled: !loaded || !error.isEmpty, action: onOpen)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(SheetSpec.padding)
            .frame(width: SheetSpec.width(preferred: 520, containerWidth: containerWidth))
            .task { await load() }
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
