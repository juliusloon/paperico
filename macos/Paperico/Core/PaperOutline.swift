import Foundation

struct PaperOutlineEntry: Codable, Identifiable, Sendable {
    let blockId: String
    let level: Int
    let heading: Bool
    let title: String
    let parentBlockId: String?
    var id: String { blockId }
}

enum PaperOutline {
    /// Preserve parser levels, infer numbered headings in older libraries, and
    /// nest evidence/paragraphs below their nearest section without rewriting data.
    static func entries(_ blocks: [Block]) -> [PaperOutlineEntry] {
        var headings: [(id: String, level: Int)] = []
        // Older MinerU output often labels every heading after the article title
        // as level 2. Recognizable research sections recover that flat hierarchy.
        let flatParser = blocks.filter { $0.kind == "section_heading" }.allSatisfy { ($0.headingLevel ?? 1) <= 2 }
        var withinResearchSection = false
        let body = zip(blocks, PaperContentScope.regions(blocks)).filter { $0.1 == .body }.map { $0.0 }
        return body.map { block in
            let heading = block.kind == "section_heading"
            let source = block.textOriginal.isEmpty ? block.sectionTitle : block.textOriginal
            let level: Int
            if heading {
                let inferred = inferredLevel(source)
                if flatParser && isResearchSection(source) {
                    level = 1
                    withinResearchSection = true
                } else if flatParser && withinResearchSection && !hasHeadingPrefix(source) {
                    level = 2
                } else {
                    level = min(4, max(1, max(block.headingLevel ?? 1, inferred)))
                }
                while let last = headings.last, last.level >= level { headings.removeLast() }
            } else {
                level = min(5, (headings.last?.level ?? 0) + 1)
            }
            let title = heading ? (block.textZh.isEmpty ? source : block.textZh)
                : (block.oneLiner.isEmpty ? (block.textZh.isEmpty ? block.textOriginal : block.textZh) : block.oneLiner)
            let result = PaperOutlineEntry(blockId: block.id, level: level, heading: heading,
                                           title: title, parentBlockId: headings.last?.id)
            if heading { headings.append((block.id, level)) }
            return result
        }
    }

    private static func hasHeadingPrefix(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(?:#+|\d+(?:\.\d+)*(?=[.\s、:：]))"#, options: .regularExpression) != nil
    }

    private static func isResearchSection(_ text: String) -> Bool {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"^(?:#+\s*|\d+[.、:]?\s+)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":：."))
        return researchSections.contains(title)
    }

    private static let researchSections: Set<String> = [
        "abstract", "introduction", "results", "results and discussion", "discussion", "conclusion", "conclusions",
        "methods", "materials and methods", "experimental procedures", "references", "data availability", "code availability",
        "acknowledgments", "acknowledgements", "author contributions", "funding", "competing interests",
        "additional information", "supplementary information", "reporting summary",
        "摘要", "引言", "结果", "结果与讨论", "讨论", "结论", "方法", "材料与方法", "参考文献", "致谢"
    ]

    static func inferredLevel(_ text: String) -> Int {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashes = source.prefix(while: { $0 == "#" }).count
        if hashes > 0 { return min(4, hashes) }
        guard let match = source.range(of: #"^\d+(?:\.\d+)*(?=[.\s、:：])"#, options: .regularExpression) else { return 1 }
        return min(4, source[match].filter { $0 == "." }.count + 1)
    }
}
