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
        regions(blocks.map {
            let visual = $0.kind == "figure" || $0.kind == "table"
            return Item(kind: $0.kind, text: visual && !$0.captionOriginal.isEmpty ? $0.captionOriginal : $0.textOriginal, section: $0.sectionTitle)
        })
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
        // Missing reference headings: require a late, consecutive bibliography
        // with author initials and publication years, not ordinary numbered prose.
        func startsReferenceRun(_ index: Int) -> Bool {
            guard index >= start + (items.count - start) / 2 else { return false }
            let lines = items[index].text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if lines.count >= 3 && lines.prefix(3).allSatisfy(isBibliographicEntry) { return true }
            return index + 2 < items.count && items[index...index + 2].allSatisfy { isBibliographicEntry($0.text) }
        }
        func startsScientificFigureRun(_ index: Int) -> Bool {
            // MinerU may retain "Additional information" as the section of all
            // Extended Data panels, with the real caption on the last panel.
            for candidate in items[index...] {
                guard candidate.kind == "figure" || candidate.kind == "table" else { return false }
                if candidate.text.range(of: #"\b(?:extended\s+data\s+|supplementary\s+)?(?:fig(?:ure)?\.?|table)\s*[a-z]?\d+\b"#,
                                        options: [.regularExpression, .caseInsensitive]) != nil { return true }
            }
            return false
        }
        // References are a section, not an irreversible end-of-document marker.
        // Nature puts Methods after References; preprints often put appendices there.
        var current: Region = .body
        var previousSection = ""
        return items.indices.map { index in
            let item = items[index]
            let section = normalized(item.section)
            let sectionChanged = !section.isEmpty && section != previousSection
            previousSection = section
            guard index >= start else { return .frontMatter }
            if isBodyHeading(item) || (sectionChanged && isBodyLabel(section)) || (current == .backMatter && startsScientificFigureRun(index)) {
                current = .body
            } else if isBackMatter(Item(kind: item.kind, text: item.text, section: sectionChanged ? item.section : "")) || startsReferenceRun(index) {
                current = .backMatter
            }
            if current == .body && isMetadata(item.text) { return .frontMatter }
            return current
        }
    }

    private static let abstractLabels: Set<String> = ["abstract", "summary", "摘要", "概要"]
    private static let introductionLabels: Set<String> = ["introduction", "background", "引言", "绪论", "背景"]
    private static let backLabels: Set<String> = [
        "references", "references and notes", "references & notes", "bibliography", "literature cited", "works cited", "参考文献", "引用文献", "文献引用",
        "acknowledgments", "acknowledgements", "致谢", "author contributions", "作者贡献",
        "data availability", "data availability statement", "code availability", "代码可用性", "数据可用性",
        "competing interests", "conflict of interest", "conflicts of interest", "利益冲突", "funding", "funding information",
        "additional information", "supplementary information", "supporting information", "补充信息", "补充材料",
        "publisher’s note", "publisher's note", "reporting summary"
    ]

    private static let bodyLabels: Set<String> = [
        "methods", "method", "materials and methods", "materials & methods", "online methods",
        "experimental procedures", "experimental section", "experimental methods", "experiments",
        "results", "results and discussion", "discussion", "conclusion", "conclusions",
        "appendix", "appendices", "supplementary methods", "supplementary results", "supplementary discussion",
        "extended data", "方法", "材料与方法", "实验方法", "实验", "结果", "讨论", "结论", "附录"
    ]

    private static func isBodyLabel(_ text: String) -> Bool {
        bodyLabels.contains(text) || text.range(of: #"^(?:appendix|appendices|附录)(?:\s+[a-z0-9]+)?(?:\s*[:：.]\s*.+)?$"#,
                                               options: .regularExpression) != nil
    }

    private static func isBodyHeading(_ item: Item) -> Bool {
        item.kind == "section_heading" && isBodyLabel(normalized(item.text))
    }

    private static func normalized(_ source: String) -> String {
        let text = source.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"^(?:#+\s*|\d+(?:\.\d+)*[.、:]?\s+)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .:："))
        let compact = text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return bodyLabels.contains(compact) || ["abstract", "summary", "introduction", "references", "bibliography", "acknowledgements", "acknowledgments"].contains(compact) ? compact : text
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

    private static func isBibliographicEntry(_ source: String) -> Bool {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let numberedAuthor = #"^(?:\[\d{1,3}\]|\d{1,3}[.)])\s+.{0,100}(?:,\s*\p{Lu}\.|\p{Lu}\.\s+\p{L})"#
        return text.range(of: numberedAuthor, options: .regularExpression) != nil &&
            text.range(of: #"\b(?:18|19|20)\d{2}\b"#, options: .regularExpression) != nil
    }

    private static func isMetadata(_ source: String) -> Bool {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        let patterns = [
            #"^(?:https?://(?:dx\.)?doi\.org/\S+|doi\s*:?\s*10\.\S+)\s*$"#,
            #"^(?:received|accepted|published(?: online)?|收稿日期|接受日期|发表日期)\s*[:：]"#,
            #"^(?:correspondence|corresponding authors?|e-?mail|authors?|affiliations?|author information|通讯作者|作者|作者单位|单位)\s*[:：]"#,
            #"^(?:<sup>[\d,*]+</sup>\s*|\d+\s*)?(?:college|department|school|institute|laboratory)\b"#,
            #"^[A-Z][a-z]+\s+[A-Z][a-z]+\s*<sup>[\d,*]+</sup>\s*,"#,
            #"^[^\n]+\.pdf$"#
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
