import Foundation

enum LibraryContextRetriever {
    struct Candidate: Equatable, Sendable { let paper: PaperListItem; let score: Int }
    static let topK = 4
    static let totalBudget = 10_000
    static let briefBudget = 2_400

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
    }
    static func terms(_ query: String) -> [String] {
        let stop = Set(["the", "a", "an", "and", "in", "of", "to", "is", "what", "how", "paper", "papers", "论文", "如何", "什么", "哪些", "方法"])
        var tokens = normalized(String(query.prefix(1000))).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for token in tokens where token.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) && token.count > 2 {
            let chars = Array(token)
            tokens += (0..<chars.count-1).map { String(chars[$0...$0+1]) }
        }
        return Array(Set(tokens.filter { !stop.contains($0) && !$0.isEmpty })).sorted()
    }
    static func rank(query: String, papers: [PaperListItem], methods: [MethodIndexItem], excluding: String?, limit: Int = topK) -> [Candidate] {
        let terms = terms(query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        var methodFields: [String: [(String, Int)]] = [:]
        for method in methods {
            let fields = [(normalized(method.name), 6), (normalized(method.definitionZh), 3)]
            for paper in method.papers { methodFields[paper.paperId, default: []] += fields }
        }
        return papers.filter { $0.id != excluding }.compactMap { paper -> Candidate? in
            let fields = [(paper.title + " " + paper.titleZh, 8), (paper.tldr, 4), (paper.domainTags.joined(separator: " "), 6),
                          (paper.authors.joined(separator: " "), 3), (paper.year.map(String.init) ?? "", 2), (paper.venue, 2)]
                .map { (normalized($0.0), $0.1) } + (methodFields[paper.id] ?? [])
            let score = fields.reduce(0) { sum, field in sum + terms.filter { field.0.contains($0) }.count * field.1 }
            return score > 0 ? Candidate(paper: paper, score: score) : nil
        }.sorted { $0.score == $1.score ? $0.paper.id < $1.paper.id : $0.score > $1.score }.prefix(limit).map { $0 }
    }

    /// Strict whole-line clipping also bounds heading-heavy papers.
    static func clipLines(_ text: String, budget: Int) -> String {
        var lines: [String] = [], remaining = max(0, budget)
        for line in text.components(separatedBy: "\n") {
            let cost = line.count + (lines.isEmpty ? 0 : 1)
            if cost > remaining { continue }
            lines.append(line); remaining -= cost
        }
        return lines.joined(separator: "\n")
    }

    static func brief(detail: PaperDetail, budget: Int, registry: inout ChatSourceRegistry) -> String {
        let title = String(detail.paper.displayTitle.prefix(200))
        let prefix = "论文：\(title)\n" + String(detail.paper.tldr.prefix(400))
        let body = ChatContextBuilder.buildPaperContext(blocks: detail.blocks, entities: detail.entities)
        guard budget >= 24 else { return "" }
        var draft = registry
        let token = draft.register(kind: .paper, paperId: detail.paper.id, title: title)
        var result = "[\(token)]"
        for line in (prefix + "\n" + body).components(separatedBy: "\n") {
            var proposed = draft
            let translated = proposed.tokenize(line, paper: detail.paper, blocks: detail.blocks)
            guard result.count + 1 + translated.count <= budget else { continue }
            result += "\n" + translated
            draft = proposed
        }
        registry = draft
        return result
    }
}
