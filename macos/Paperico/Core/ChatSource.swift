import Foundation

struct ChatSourceRef: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case block, paper, method }
    var token: String
    var kind: Kind
    var paperId: String?
    var blockId: String?
    var methodKey: String?
    var title: String?

    func label(currentPaperId: String?) -> String {
        let shortTitle = String((title ?? "来源").prefix(24))
        switch kind {
        case .paper: return "论文 · " + shortTitle
        case .method: return "方法 · " + shortTitle
        case .block:
            let evidence = "证据 " + (blockId?.split(separator: "-").last.map(String.init) ?? token)
            return paperId == currentPaperId ? evidence : "《\(shortTitle)》 · \(evidence)"
        }
    }
}

/// Each round owns its registry. A source becomes eligible only when its content is sent.
struct ChatSourceRegistry: Sendable {
    private(set) var sources: [ChatSourceRef] = []
    private var next = 1
    @discardableResult
    mutating func register(kind: ChatSourceRef.Kind, paperId: String? = nil, blockId: String? = nil,
                           methodKey: String? = nil, title: String? = nil, token: String? = nil) -> String {
        if let existing = sources.first(where: { $0.kind == kind && $0.paperId == paperId && $0.blockId == blockId && $0.methodKey == methodKey }) {
            return existing.token
        }
        let value: String
        if let token { value = token } else { value = String(format: "s%03d", next); next += 1 }
        guard !sources.contains(where: { $0.token == value }) else { return value }
        sources.append(ChatSourceRef(token: value, kind: kind, paperId: paperId, blockId: blockId, methodKey: methodKey, title: title))
        return value
    }
    mutating func registerCurrent(blocks: [Block], paperId: String, context: String) {
        for block in blocks where context.contains(block.id) {
            register(kind: .block, paperId: paperId, blockId: block.id, token: block.id)
        }
    }
    func validatedSources(in answer: String) -> [ChatSourceRef] {
        let lookup = Dictionary(uniqueKeysWithValues: sources.map { ($0.token, $0) })
        var seen = Set<String>()
        return ChatCitation.matches(in: answer, validIds: Set(lookup.keys)).compactMap { match in
            seen.insert(match.blockId).inserted ? lookup[match.blockId] : nil
        }
    }
    /// Translate cross-paper refs only after a bounded semantic line has been selected.
    mutating func tokenize(_ text: String, paper: PaperListItem, blocks: [Block]) -> String {
        var result = text
        for block in blocks where result.contains(block.id) {
            let token = register(kind: .block, paperId: paper.id, blockId: block.id, title: paper.displayTitle)
            result = result.replacingOccurrences(of: block.id, with: token)
        }
        return result
    }
}
