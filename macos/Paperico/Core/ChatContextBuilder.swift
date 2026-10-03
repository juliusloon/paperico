import Foundation

/// 分层、限额的对话上下文组装(逐字移植 backend/app/services/context.py)。
///
/// 截断只发生在完整语义行上;章节标题永远保留。行形:
///   逻辑链   `角色 · [b00xx] 一句话；[b00xx] 一句话`
///   方法索引 `Name(CATEGORY) → [b00xx,b00yy]`
enum ChatContextBuilder {

    static let logicChainBudget = 6000
    static let oneLinerLimit = 120
    static let methodIndexTopK = 40
    static let methodIndexRefLimit = 12
    static let selectionSnippetLimit = 6000
    static let attachedContextBudget = 18000
    static let figureSummaryLimit = 400

    static func clipText(_ value: String?, limit: Int) -> String {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).dropSuffixWhitespace() + "…"
    }

    /// 把全文 blocks 压缩成按角色分组的逻辑链行(对齐 compact_logic_chain)。
    ///
    /// 超预算时从尾部开始整行丢弃;章节标题无条件保留——它们是模型导航的结构锚点。
    static func compactLogicChain(_ blocks: [Block], budget: Int = logicChainBudget) -> String {
        var entries: [(isHeading: Bool, line: String)] = []
        var groupRefs: [String] = []
        var groupRole = ""

        func flushGroup() {
            guard !groupRefs.isEmpty else { return }
            let role = groupRole.isEmpty ? "内容" : groupRole
            entries.append((false, "\(role) · \(groupRefs.joined(separator: "；"))"))
            groupRefs = []
            groupRole = ""
        }

        for block in blocks {
            let oneLiner = clipText(block.oneLiner, limit: oneLinerLimit)
            if block.kind == "section_heading" {
                flushGroup()
                let titleSource = block.textOriginal.isEmpty ? block.sectionTitle : block.textOriginal
                let title = clipText(titleSource.isEmpty ? oneLiner : titleSource, limit: oneLinerLimit)
                entries.append((true, "§ [\(block.id)] \(title)"))
                continue
            }
            if oneLiner.isEmpty { continue }
            let role = block.roleInNarrative.isEmpty ? "内容" : block.roleInNarrative
            if role != groupRole {
                flushGroup()
                groupRole = role
            }
            groupRefs.append("[\(block.id)] \(oneLiner)")
        }
        flushGroup()

        func totalLength() -> Int {
            entries.reduce(0) { $0 + $1.line.count + 1 }
        }
        while totalLength() > budget {
            guard let tail = entries.lastIndex(where: { !$0.isHeading }) else { break }
            entries.remove(at: tail)
        }
        return entries.map(\.line).joined(separator: "\n")
    }

    /// 按提及次数排序方法实体,渲染 name(category) → [refs](对齐 compact_method_index)。
    static func compactMethodIndex(_ entities: [MethodEntity], topK: Int = methodIndexTopK) -> String {
        let ranked = entities
            .sorted { $0.blockRefs.count > $1.blockRefs.count }
            .prefix(topK)
        var lines: [String] = []
        for entity in ranked {
            let shown = entity.blockRefs.prefix(methodIndexRefLimit)
            let overflow = entity.blockRefs.count > shown.count ? "…(+\(entity.blockRefs.count - shown.count))" : ""
            let name = entity.name.isEmpty ? "?" : entity.name
            let category = entity.category.isEmpty ? "OTHER" : entity.category
            lines.append("\(name)(\(category)) → [\(shown.joined(separator: ","))]\(overflow)")
        }
        return lines.joined(separator: "\n")
    }

    /// 手动附带上下文(选中文本/方法卡/图表),保留选中段落的原文，并限制单段与整体上下文大小。
    static func buildAttachedText(_ contexts: [AttachedContext], blocks: [Block], entities: [MethodEntity]) -> String {
        var attachedText = ""
        for ctx in contexts {
            switch ctx.typeEnum {
            case .textSelection:
                if let refBlockId = ctx.refBlockId,
                   let block = blocks.first(where: { $0.id == refBlockId }) {
                    attachedText += "\n[引用段落 \(block.id)]: \(clipText(block.textOriginal, limit: selectionSnippetLimit))"
                } else if let snippet = ctx.snippet {
                    attachedText += "\n[PDF 选中文本]: \(clipText(snippet, limit: selectionSnippetLimit))"
                }
            case .methodCard:
                if let refEntityId = ctx.refEntityId,
                   let entity = entities.first(where: { $0.id == refEntityId }) {
                    attachedText += "\n[方法实体 \(entity.name)]: 定义 \(entity.definitionZh)，出现于 \(entity.blockRefs.joined(separator: ","))"
                }
            case .figure:
                if let refBlockId = ctx.refBlockId,
                   let block = blocks.first(where: { $0.id == refBlockId }) {
                    let takeaways = block.coreTakeaways.joined(separator: ", ")
                    let summary = clipText(
                        [block.captionOriginal, takeaways].filter { !$0.isEmpty }.joined(separator: "；"),
                        limit: figureSummaryLimit
                    )
                    attachedText += "\n[图表 \(block.id)]: \(summary)"
                }
            case .presetPrompt, .unknown:
                continue
            }
        }
        return clipText(attachedText, limit: attachedContextBudget)
    }

    /// 组装对话系统提示词用的两段上下文(对齐 build_paper_context)。
    static func buildPaperContext(blocks: [Block], entities: [MethodEntity]) -> String {
        [
            "【全文逻辑链（压缩版，按原文顺序）】\n" + compactLogicChain(blocks),
            "【已识别方法/实体索引】\n" + compactMethodIndex(entities),
        ].joined(separator: "\n\n")
    }
}

private extension String {
    /// Python 的 `text[:limit].rstrip()`:去掉截断后尾部的空白。
    func dropSuffixWhitespace() -> String {
        var copy = self
        while let last = copy.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            copy.removeLast()
        }
        return copy
    }
}
