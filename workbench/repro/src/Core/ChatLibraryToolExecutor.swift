import Foundation
import CoreFoundation

/// Only these five schemas reach the model. Execution uses active library records directly.
struct ChatLibraryToolExecutor {
    let library: PaperLibrary
    let papers: [PaperListItem]
    let methods: [MethodIndexItem]
    struct Output {
        var content: String
        var paperIds: Set<String> = []
        var clipped = false
        var rankingMilliseconds: Double?
    }
    static var schemas: [[String: Any]] {
        func schema(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": properties,
                                                                                                  "required": required, "additionalProperties": false]]]
        }
        let query: [String: Any] = ["type": "string", "minLength": 1, "maxLength": 1000]
        let id: [String: Any] = ["type": "string", "maxLength": 128]
        let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 20]
        return [
            schema("search_library", "Search local library metadata and methods; prefer this before reading full blocks.", ["query": query, "limit": limit], ["query"]),
            schema("search_methods", "Search local method names and definitions.", ["query": query, "category": ["type": "string"], "limit": limit], ["query"]),
            schema("get_paper", "Read metadata, outline and method overview of a library paper.", ["paper_id": id], ["paper_id"]),
            schema("resource_brief", "Read a compact library paper brief before fetching blocks.", ["paper_id": id], ["paper_id"]),
            schema("get_blocks", "Read up to 12 original blocks from a library paper.", ["paper_id": id, "block_ids": ["type": "array", "items": id, "maxItems": 12],
                                                                                     "offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 12]], ["paper_id"])
        ]
    }
    private func identifier(_ value: Any?) throws -> String {
        guard let value = value as? String, !value.isEmpty, value.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw AutomationError("库内 ID 无效。")
        }
        return value
    }
    private func integer(_ args: [String: Any], _ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw = args[key] else { return defaultValue }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = raw as? Int, range.contains(value) else { throw AutomationError("\(key) 超出允许范围。") }
        return value
    }
    private func query(_ args: [String: Any]) throws -> String {
        guard let raw = args["query"] as? String, raw.count <= 1000, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationError("需要长度不超过 1000 的非空 query。")
        }
        return raw
    }
    func execute(_ call: LLMToolCall, registry: inout ChatSourceRegistry, budget: Int) async throws -> Output {
        try Task.checkCancellation()
        var draft = registry
        var rankingMilliseconds: Double?
        do {
            let args = try call.decodedArguments()
            let allowed: [String: Set<String>] = ["search_library": ["query", "limit"], "search_methods": ["query", "category", "limit"],
                                                 "get_paper": ["paper_id"], "resource_brief": ["paper_id"], "get_blocks": ["paper_id", "block_ids", "offset", "limit"]]
            guard let keys = allowed[call.name], Set(args.keys).isSubset(of: keys) else { throw AutomationError("不支持的工具或参数。") }
            var lines: [(String, ChatSourceRef?)] = []
            var selectedPaperIds = Set<String>()
            switch call.name {
            case "search_library":
                let query = try query(args), limit = try integer(args, "limit", default: 4, range: 1...20)
                let rankingStart = Date()
                let candidates = LibraryContextRetriever.rank(query: query, papers: papers, methods: methods, excluding: nil, limit: limit)
                rankingMilliseconds = Date().timeIntervalSince(rankingStart) * 1000
                for candidate in candidates {
                    guard await library.paper(id: candidate.paper.id) != nil else { continue }
                    let p = candidate.paper
                    lines.append(("paper_id=\(p.id) · \(String(p.displayTitle.prefix(200))) · \(String(p.tldr.prefix(400)))",
                                  ChatSourceRef(token: "", kind: .paper, paperId: p.id, title: p.displayTitle)))
                }
            case "search_methods":
                let terms = LibraryContextRetriever.terms(try query(args))
                let limit = try integer(args, "limit", default: 4, range: 1...20)
                if let value = args["category"], !(value is String) { throw AutomationError("category 必须是字符串。") }
                let category = args["category"] as? String
                var ranked: [(MethodIndexItem, Int)] = []
                for method in methods {
                    if let category, method.category != category { continue }
                    let text = LibraryContextRetriever.normalized(method.name + " " + method.definitionZh)
                    let score = terms.filter { text.contains($0) }.count
                    if score > 0 { ranked.append((method, score)) }
                }
                ranked.sort { lhs, rhs in lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1 }
                for (method, _) in ranked.prefix(limit) {
                    var active: [String] = []
                    for paper in method.papers where await library.paper(id: paper.paperId) != nil { active.append(paper.paperId) }
                    guard !active.isEmpty else { continue }
                    lines.append(("\(String(method.name.prefix(200))) · \(String(method.definitionZh.prefix(600))) · paper_ids=\(active.joined(separator: ","))",
                                  ChatSourceRef(token: "", kind: .method, paperId: active.first, methodKey: method.id, title: method.name)))
                }
            default:
                let paperId = try identifier(args["paper_id"])
                let detail = try await library.paperDetail(id: paperId, markOpened: false)
                try Task.checkCancellation()
                if call.name == "resource_brief" {
                    let content = LibraryContextRetriever.brief(detail: detail, budget: min(3000, max(0, budget - 700)), registry: &draft)
                    lines.append((content, nil))
                    selectedPaperIds.insert(paperId)
                } else if call.name == "get_paper" {
                    let p = detail.paper
                    lines.append(("paper_id=\(p.id) · \(String(p.displayTitle.prefix(200))) · \(p.authors.joined(separator: ", ")) · \(p.year.map(String.init) ?? "") · \(p.venue) · DOI=\(p.doi ?? "")",
                                  ChatSourceRef(token: "", kind: .paper, paperId: paperId, title: p.displayTitle)))
                    for entry in PaperOutline.entries(detail.blocks) {
                        lines.append(("§ " + String(entry.title.prefix(200)), nil))
                    }
                    for entity in detail.entities.prefix(20) { lines.append((String(entity.name.prefix(200)), nil)) }
                } else {
                    let offset = try integer(args, "offset", default: 0, range: 0...Int.max)
                    let limit = try integer(args, "limit", default: 12, range: 1...12)
                    var blocks: [Block]
                    if let requested = args["block_ids"] {
                        guard let values = requested as? [String], values.count <= 12 else { throw AutomationError("block_ids 最多包含 12 个 ID。") }
                        let ids = try values.map { try identifier($0) }
                        guard ids.allSatisfy({ id in detail.blocks.contains { $0.id == id } }) else { throw AutomationError("论文中没有该 block_id。") }
                        blocks = ids.compactMap { id in detail.blocks.first { $0.id == id } }
                    } else { blocks = Array(detail.blocks.dropFirst(min(offset, detail.blocks.count)).prefix(limit)) }
                    blocks = Array(blocks.prefix(limit))
                    for block in blocks {
                        let text = [block.textOriginal, block.captionOriginal, block.latex, block.tableHtml].filter { !$0.isEmpty }.joined(separator: "\n")
                        lines.append(("block_id=\(block.id) · \(String(block.sectionTitle.prefix(200)))\n\(String(text.prefix(3000)))",
                                      ChatSourceRef(token: "", kind: .block, paperId: paperId, blockId: block.id, title: detail.paper.displayTitle)))
                    }
                }
            }
            var outputLines: [String] = []
            let beforeTokens = Set(registry.sources.map(\.token))
            func encoded(_ lines: [String], _ refs: [ChatSourceRef], clipped: Bool) -> String {
                let refs = refs.map { ref -> [String: Any] in
                    var value: [String: Any] = ["token": ref.token, "kind": ref.kind.rawValue]
                    if let id = ref.paperId { value["paper_id"] = id }
                    if let id = ref.blockId { value["block_id"] = id }
                    if let key = ref.methodKey { value["method_key"] = key }
                    return value
                }
                return AnalysisEngine.jsonString(["untrusted_content": true, "data": lines, "source_refs": refs, "clipped": clipped, "budget": budget])
            }
            var clipped = false
            for (text, source) in lines {
                var trial = draft
                var line = text
                if let source {
                    let token = trial.register(kind: source.kind, paperId: source.paperId, blockId: source.blockId, methodKey: source.methodKey, title: source.title)
                    line = "[\(token)] " + line
                }
                let refs = trial.sources.filter { !beforeTokens.contains($0.token) }
                guard encoded(outputLines + [line], refs, clipped: true).count <= budget else { clipped = true; continue }
                outputLines.append(line); draft = trial
                if let id = source?.paperId { selectedPaperIds.insert(id) }
            }
            // If a brief did not fit its wrapper, discard its tentative registrations.
            if outputLines.isEmpty { draft = registry; selectedPaperIds = [] }
            let output = encoded(outputLines, draft.sources.filter { !beforeTokens.contains($0.token) }, clipped: clipped)
            guard output.count <= budget else { return Output(content: "", clipped: true) }
            try Task.checkCancellation()
            registry = draft
            return Output(content: output, paperIds: selectedPaperIds, clipped: clipped, rankingMilliseconds: rankingMilliseconds)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let output = AnalysisEngine.jsonString(["error": String(error.localizedDescription.prefix(200)), "untrusted_content": true])
            return Output(content: output.count <= budget ? output : "", clipped: output.count > budget)
        }
    }
}
