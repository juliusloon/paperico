import Foundation

/// Detect reading boundaries without deleting source blocks or changing their IDs.
/// A missing abstract is handled conservatively; inline scientific citations stay body text.
enum PaperContentScope {
    enum Region: String { case frontMatter, body, backMatter }

    struct Item {
        let kind: String
        let text: String
        let section: String
    }

    static func regions(_ blocks: [Block]) -> [Region] {
        regions(blocks.map { Item(kind: $0.kind, text: $0.textOriginal, section: $0.sectionTitle) })
    }

    static func regions(_ items: [Item]) -> [Region] {
        guard !items.isEmpty else { return [] }
        let abstract = items.firstIndex { isStart($0, labels: abstractLabels) }
        let introduction = items.firstIndex { isStart($0, labels: introductionLabels) }
        var start = abstract ?? introduction ?? 0
        // Journals such as Nature often omit an "Abstract" heading. Preserve the
        // substantive opening summary, while omitting title/authors/publication data.
        if abstract == nil, let introduction {
            if let summary = items[..<introduction].firstIndex(where: {
                $0.kind == "paragraph" && $0.text.count >= 220 && !isMetadata($0.text)
            }) { start = summary }
        }
        if abstract == nil, introduction == nil,
           items.prefix(12).contains(where: { isMetadata($0.text) }),
           let summary = items.firstIndex(where: {
               $0.kind == "paragraph" && $0.text.count >= 220 && !isMetadata($0.text)
           }) {
            start = summary
        }
        let end = items.indices.first { index in
            index >= start && isBackMatter(items[index])
        } ?? items.count
        return items.indices.map { index in
            if index >= end { return .backMatter }
            if index < start || isMetadata(items[index].text) { return .frontMatter }
            return .body
        }
    }

    private static let abstractLabels: Set<String> = ["abstract", "summary", "摘要", "概要"]
    private static let introductionLabels: Set<String> = ["introduction", "background", "引言", "绪论", "背景"]
    private static let backLabels: Set<String> = [
        "references", "bibliography", "literature cited", "works cited", "参考文献", "引用文献", "文献引用",
        "acknowledgments", "acknowledgements", "致谢", "author contributions", "作者贡献",
        "data availability", "data availability statement", "code availability", "代码可用性", "数据可用性",
        "competing interests", "conflict of interest", "conflicts of interest", "利益冲突", "funding", "funding information",
        "additional information", "supplementary information", "supporting information", "补充信息", "补充材料",
        "publisher’s note", "publisher's note", "reporting summary"
    ]

    private static func normalized(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"^(?:#+\s*|\d+(?:\.\d+)*[.、:]?\s+)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:："))
    }

    private static func isStart(_ item: Item, labels: Set<String>) -> Bool {
        if labels.contains(normalized(item.section)) { return true }
        let text = normalized(item.text)
        if labels.contains(text) { return true }
        return labels.contains { label in text.hasPrefix(label + ":") || text.hasPrefix(label + "：") || text.hasPrefix(label + "\n") }
    }

    private static func isBackMatter(_ item: Item) -> Bool {
        if backLabels.contains(normalized(item.section)) { return true }
        let text = normalized(item.text)
        return backLabels.contains(text) || (item.kind == "section_heading" && backLabels.contains {
            text.hasPrefix($0 + "\n") || text.hasPrefix($0 + ":") || text.hasPrefix($0 + "：")
        })
    }

    private static func isMetadata(_ source: String) -> Bool {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        let patterns = [
            #"^(?:https?://(?:dx\.)?doi\.org/\S+|doi\s*:?\s*10\.\S+)\s*$"#,
            #"^(?:received|accepted|published(?: online)?|收稿日期|接受日期|发表日期)\s*[:：]"#,
            #"^(?:correspondence|corresponding author|e-?mail|通讯作者)\s*[:：]"#,
            #"^(?:<sup>[\d,*]+</sup>\s*|\d+\s*)?(?:college|department|school|institute|laboratory)\b"#,
            #"^[A-Z][a-z]+\s+[A-Z][a-z]+\s*<sup>[\d,*]+</sup>\s*,"#,
            #"^[^\n]+\.pdf$"#
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
