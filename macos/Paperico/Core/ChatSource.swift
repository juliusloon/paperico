import Foundation

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
        if let token, !sources.contains(where: { $0.token == token }) { value = token }
        else {
            var candidate: String
            repeat { candidate = String(format: "s%03d", next); next += 1 }
            while sources.contains(where: { $0.token == candidate })
            value = candidate
        }
        sources.append(ChatSourceRef(token: value, kind: kind, paperId: paperId, blockId: blockId, methodKey: methodKey, title: title))
        return value
    }
    mutating func registerCurrent(blocks: [Block], paperId: String, context: String) {
        for block in blocks where Self.idRange(block.id, in: context) != nil {
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
        for block in blocks {
            if Self.idRange(block.id, in: result) != nil {
                let token = register(kind: .block, paperId: paper.id, blockId: block.id, title: paper.displayTitle)
                result = result.replacingOccurrences(of: Self.idPattern(block.id), with: token, options: .regularExpression)
            }
        }
        return result
    }
    private static func idRange(_ id: String, in text: String) -> Range<String.Index>? {
        text.range(of: idPattern(id), options: .regularExpression)
    }
    private static func idPattern(_ id: String) -> String {
        "(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: id) + "(?![A-Za-z0-9_-])"
    }
}
