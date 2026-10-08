import Foundation

/// Opt-in only. Expectations use sections and phrases; parser block IDs are never fixtures.
enum CitationAcceptance {
    struct Manifest: Decodable { var papers: [Paper] }
    struct Paper: Decodable { var file: String; var questions: [Question] }
    struct Question: Decodable {
        var q: String
        var expect: Expectation
        var library: Bool?
        var expectPapers: [String]?
        var requireTools: Bool?
        var requiredTools: [String]?
        var requireBlockEvidence: Bool?
        var maxReadPapers: Int?
    }
    struct Expectation: Decodable { var section: String?; var mustContain: [String]? }
    // Release quality thresholds only rise. Do not tune prompts against this manifest.
    static let minimumHitRate = 0.7
    static let maximumFabrications = 0

    static func citationTokens(_ answer: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\[(b[A-Za-z0-9_-]*\d|s\d+)\]"#)
        let ns = answer as NSString
        let tokens = Set(regex.matches(in: answer, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
        return ChatCitation.matches(in: answer, validIds: tokens).map(\.blockId)
    }

    @MainActor
    static func run(manifestURL: URL, library: PaperLibrary, config: AnalysisEngine.LLMConfig, output: URL,
                    environment: [String: String]) async throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard !manifest.papers.isEmpty, manifest.papers.contains(where: { !$0.questions.isEmpty }) else { throw PipelineError("Citation manifest contains no questions") }
        let papers = await library.listPapers()
        var llm = config
        llm.temperature = 0; llm.maxTokens = 2048
        let mode = environment["PAPERICO_E2E_CHAT_MODE"] ?? "fallback"
        guard ["agent", "fallback"].contains(mode) else { throw PipelineError("PAPERICO_E2E_CHAT_MODE must be agent or fallback") }
        if mode == "agent" {
            let supported = await LLMProbe.probeTools(base: llm.baseURL, apiKey: llm.apiKey, model: llm.model)
            guard supported == true else { throw PipelineError("Agent acceptance requires a verified tool-capable provider") }
            llm.supportsTools = true
        } else { llm.supportsTools = false }
        var rows: [[String: Any]] = []
        var totalCitations = 0, hits = 0, fabricated = 0, nonempty = 0
        var totalRounds = 0, totalCalls = 0, totalRead = 0, fallbackHits = 0, expectedFailures = 0
        var rankingTimes: [Double] = [], toolTimes: [Double] = []
        for item in manifest.papers {
            guard let paper = papers.first(where: { $0.originalFileName == item.file }) else { throw PipelineError("Manifest paper missing: \(item.file)") }
            for question in item.questions {
                guard !question.q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      question.expect.section?.isEmpty == false || question.expect.mustContain?.isEmpty == false else {
                    throw PipelineError("Every question needs text and a section or phrase expectation")
                }
                var answer = "", sessionId: String?, rounds = 0, calls = 0, read = 0
                var agentRanking: [Double] = [], toolIO: [Double] = [], toolNames: [String] = []
                for try await event in ChatService.send(paperId: paper.id, content: question.q, sessionId: nil, attachedContext: nil,
                                                       library: library, llm: llm, allowLibraryContext: question.library ?? false) {
                    answer += event.content ?? ""
                    sessionId = event.sessionId ?? sessionId
                    calls = max(calls, event.libraryQueryCount ?? 0)
                    read = max(read, event.libraryPaperCount ?? 0)
                    rounds = max(rounds, event.libraryToolRounds ?? 0)
                    if let ms = event.retrievalMilliseconds { rankingTimes.append(ms) }
                    if let samples = event.agentRankingMilliseconds { agentRanking = samples }
                    if let samples = event.toolMilliseconds { toolIO = samples }
                    if let names = event.libraryToolNames { toolNames = names }
                }
                rankingTimes += agentRanking; toolTimes += toolIO
                let session = try await library.chatSession(paperId: paper.id, sessionId: sessionId ?? "")
                let sources = session?.messages.last?.sourceRefs ?? []
                let sourceMap = Dictionary(sources.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
                let tokens = citationTokens(answer)
                var citationRows: [[String: Any]] = [], citedPapers = Set<String>(), blockPapers = Set<String>(), questionHits = 0
                var questionFabricated = 0
                for token in tokens {
                    // Report the resolved coordinates of every citation so failed questions can be reviewed by hand.
                    var matched = false
                    var row: [String: Any] = ["token": token]
                    if let source = sourceMap[token], let sourcePaper = source.paperId,
                       let record = papers.first(where: { $0.id == sourcePaper }) {
                        citedPapers.insert(record.originalFileName)
                        row["paper"] = record.originalFileName
                        if let blockId = source.blockId {
                            row["block"] = blockId
                            let blocks = try await library.readBlocks(paperId: sourcePaper)
                            if let block = blocks.first(where: { $0.id == blockId }) {
                                blockPapers.insert(record.originalFileName)
                                row["section"] = block.sectionTitle
                                let sectionMatches = question.expect.section.map { block.sectionTitle.localizedCaseInsensitiveContains($0) || (block.kind == "section_heading" && block.textOriginal.localizedCaseInsensitiveContains($0)) } ?? false
                                let text = block.textOriginal + " " + block.captionOriginal + " " + block.latex
                                matched = sectionMatches || (question.expect.mustContain ?? []).contains { text.localizedCaseInsensitiveContains($0) }
                            } else { questionFabricated += 1 }
                        } else {
                            matched = (question.expectPapers ?? []).contains(record.originalFileName)
                        }
                    } else { questionFabricated += 1 }
                    if matched { questionHits += 1 }
                    row["matched"] = matched
                    citationRows.append(row)
                }
                let expectedPaperHit = (question.expectPapers ?? []).allSatisfy { citedPapers.contains($0) }
                let toolExpectation = mode != "agent" || ((question.requireTools != true || calls > 0) && (question.requiredTools ?? []).allSatisfy { toolNames.contains($0) })
                let blockExpectation = question.requireBlockEvidence != true || (question.expectPapers ?? []).allSatisfy { blockPapers.contains($0) }
                let readExpectation = question.maxReadPapers.map { read <= $0 } ?? true
                if !expectedPaperHit || !toolExpectation || !readExpectation || !blockExpectation { expectedFailures += 1 }
                if mode == "fallback", question.library == true, expectedPaperHit, !(question.expectPapers ?? []).isEmpty { fallbackHits += 1 }
                totalCitations += tokens.count; hits += questionHits; fabricated += questionFabricated
                if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { nonempty += 1 }
                totalRounds += rounds; totalCalls += calls; totalRead += read
                rows.append(["file": item.file, "question": question.q, "answer": answer, "citations": citationRows,
                             "fabricated": questionFabricated, "expected_paper_hit": expectedPaperHit, "tool_expectation_met": toolExpectation,
                             "tool_rounds": rounds, "tool_calls": calls, "read_papers": read, "tool_io_ms": toolIO, "tool_names": toolNames, "block_expectation_met": blockExpectation])
            }
        }
        let hitRate = Double(hits) / Double(max(1, totalCitations))
        let nonemptyRate = Double(nonempty) / Double(max(1, rows.count))
        let sorted = rankingTimes.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        let passed = totalCitations > 0 && hitRate >= minimumHitRate && fabricated == maximumFabrications && nonemptyRate == 1 && expectedFailures == 0 && p95 < 150
        let report: [String: Any] = ["mode": mode, "passed": passed, "citation_hit_rate": hitRate, "fabricated_citations": fabricated,
            "answer_nonempty_rate": nonemptyRate, "mean_tool_rounds": Double(totalRounds)/Double(max(1, rows.count)),
            "mean_tool_calls": Double(totalCalls)/Double(max(1, rows.count)), "mean_read_papers": Double(totalRead)/Double(max(1, rows.count)),
            "fallback_hits": fallbackHits, "ranking_p95_ms": sorted.isEmpty ? NSNull() : p95 as Any,
            "ranking_samples": rankingTimes, "tool_io_ms": toolTimes, "questions": rows]
        try LibraryFiles.writeJSONAny(report, to: output.appendingPathComponent("citations-\(mode).json"))
        print("CITATIONS mode=\(mode) hit=\(hitRate) fabricated=\(fabricated) nonempty=\(nonemptyRate) questions=\(rows.count) passed=\(passed)")
        guard passed else { throw PipelineError("Citation acceptance failed; see citations-\(mode).json") }
    }
}
