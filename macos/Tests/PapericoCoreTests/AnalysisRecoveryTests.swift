import Foundation
import XCTest
@testable import PapericoCore

private final class SingleAnalysisProtocol: URLProtocol {
    static let lock = NSLock()
    static var completionCount = 0
    static var seenBlocks: [[String: Any]] = []
    static var seenCatalog: [String: Any] = [:]
    static var requestedBudget = 0
    static var translationBatches: [[String]] = []
    static var mode = "complete"

    static func reset(_ mode: String = "complete") {
        lock.lock(); defer { lock.unlock() }
        completionCount = 0; seenBlocks = []; seenCatalog = [:]; requestedBudget = 0; translationBatches = []; self.mode = mode
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/models" {
            respond(status: 200, data: Data(#"{"data":[{"id":"test","limit":{"output":32768,"context":262144}}]}"#.utf8))
            return
        }
        let payload = try! JSONSerialization.jsonObject(with: body()) as! [String: Any]
        // Single analysis must omit provider-specific temperature constraints.
        XCTAssertNil(payload["temperature"])
        // Avoid grammar-constrained JSON mode: compatible servers can get stuck
        // emitting whitespace after a quote instead of completing the document.
        XCTAssertNil(payload["response_format"])
        if (payload["model"] as? String ?? "").lowercased().contains("qwen3.5") {
            XCTAssertNil(payload["reasoning_effort"])
            XCTAssertEqual((payload["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], false)
        } else { XCTAssertEqual(payload["reasoning_effort"] as? String, "low") }
        let messages = payload["messages"] as! [[String: Any]]
        let content = messages.last!["content"] as! String
        let metadataOnly = messages.first!["content"] as? String == AnalysisEngine.metadataPrompt
        let translationOnly = messages.first!["content"] as? String == AnalysisEngine.chunkTranslationPrompt
        let input: [[String: Any]]
        if metadataOnly {
            input = try! JSONSerialization.jsonObject(with: Data(content.components(separatedBy: "全文原始节点：").last!.utf8)) as! [[String: Any]]
        } else {
            let sources = try! JSONSerialization.jsonObject(with: Data(content.components(separatedBy: "逐项完整处理以下 MinerU 结果：\n").last!.utf8)) as! [String: [String: Any]]
            let manifest = content.components(separatedBy: .newlines).first { $0.hasPrefix("nodes 必须恰好包含") }!.components(separatedBy: "个键：").last!
            let ids = try! JSONSerialization.jsonObject(with: Data(manifest.utf8)) as! [String]
            input = ids.map { id -> [String: Any] in var block = sources[id]!; block["id"] = id; return block }
        }
        Self.lock.lock()
        Self.completionCount += 1; Self.seenBlocks = input;
        if translationOnly { Self.translationBatches.append(input.map { $0["id"] as! String }) }
        if let catalogLine = content.components(separatedBy: .newlines).first(where: { $0.hasPrefix("当前方法目录：") }) {
            Self.seenCatalog = (try? JSONSerialization.jsonObject(with: Data(catalogLine.dropFirst("当前方法目录：".count).utf8))) as? [String: Any] ?? [:]
        }
        Self.requestedBudget = payload["max_tokens"] as! Int
        let mode = Self.mode == "missingSecondBatch" && Self.completionCount == 2 ? "missing" : Self.mode
        Self.lock.unlock()
        if mode == "denied" {
            respond(status: 401, data: Data(#"{"error":{"message":"invalid test key"}}"#.utf8)); return
        }
        let paper: [String: Any] = ["title": "A real title", "title_zh": "中文标题", "tldr": "核心结论", "narrative_summary": "根据全文原文建立逻辑关系。", "contributions": ["新的方法"], "domain_tags": ["机器学习"], "difficulty_estimate": "中等"]
        var records: [[String: Any]] = [["paper": paper]]
        for block in (metadataOnly ? [] : mode == "missing" ? Array(input.dropLast()) : input) {
            let length = (block["text"] as? String ?? "").count
            let translation = length >= 180 ? String(repeating: "完整中文翻译，包含全部原文细节和科学证据。", count: max(1, (length + 79) / 80)) : "完整中文翻译"
            var node: [String: Any] = ["id": block["id"]!, "source_start": block["source_start"]!, "zh": translation, "note": "具体中文要点", "role": "方法设计"]
            if mode == "sourceMismatch" { node["source_start"] = "A different paragraph" }
            if mode == "missingSource" { node.removeValue(forKey: "source_start") }
            records.append(node)
        }
        records.append(["methods": [["name": "Graph model", "category": mode == "customGroup" ? "custom_group" : "ML_MODEL", "definition_zh": "学习分子性质", "refs": [mode == "badRef" ? "invented-id" : input.first!["id"]!]]]])
        let nodeMap = Dictionary(uniqueKeysWithValues: records.dropFirst().dropLast().map { node -> (String, [String: Any]) in
            var value = node; let id = value.removeValue(forKey: "id") as! String
            return (id, value)
        })
        let document: [String: Any] = metadataOnly ? ["paper": paper, "methods": records.last!["methods"]!] : translationOnly ? ["nodes": nodeMap] : ["paper": paper, "methods": records.last!["methods"]!, "nodes": nodeMap]
        let lines: String
        if mode == "whitespace" { lines = "{\"nodes\":{" + String(repeating: "\t", count: 4096) }
        else if mode == "methodLoop" {
            let method = #"{"name":"Copied method","category":"ALGORITHM","existing_key":"copied","definition_zh":"无证据重复目录","refs":[]}"#
            lines = "{\"methods\":[" + Array(repeating: method, count: 8).joined(separator: ",")
        } else { lines = AnalysisEngine.jsonString(document) }
        if payload["stream"] as? Bool == true {
            // Split inside JSON records and UTF-8-safe character boundaries to exercise incremental assembly.
            let chunks = stride(from: 0, to: lines.count, by: 37).map { offset -> String in
                let start = lines.index(lines.startIndex, offsetBy: offset)
                let end = lines.index(start, offsetBy: min(37, lines.count - offset))
                return String(lines[start..<end])
            }
            var sse = chunks.map { chunk in
                "data: " + AnalysisEngine.jsonString(["choices": [["delta": ["content": chunk]]]]) + "\n\n"
            }.joined()
            sse += "data: " + AnalysisEngine.jsonString(["choices": [["delta": [:], "finish_reason": mode == "length" ? "length" : "stop"]]]) + "\n\n"
            sse += "data: [DONE]\n\n"
            respond(status: 200, data: Data(sse.utf8), type: "text/event-stream")
        } else {
            respond(status: 200, data: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": lines], "finish_reason": "stop"]]]))
        }
    }
    private func body() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    private func respond(status: Int, data: Data, type: String = "application/json") {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor CaptureLog {
    var value: [String: Any] = [:]
    var progress: [Int] = []
    func save(_ value: [String: Any]) { self.value = value }
    func step(_ value: Int) { progress.append(value) }
}

final class SingleAnalysisTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SingleAnalysisProtocol.self]
        return URLSession(configuration: config)
    }
    private func blocks(_ count: Int = 25) -> [[String: Any]] {
        (0..<count).map { ["id": "original-\($0)", "kind": "paragraph", "text_original": "Original full paragraph \($0)", "section_title": "Methods"] }
    }
    private func llm(_ streaming: Bool = true) -> AnalysisEngine.LLMConfig {
        AnalysisEngine.LLMConfig(baseURL: "https://model.test", apiKey: "test", model: "test", reasoningEffort: "medium", streaming: streaming)
    }

    func testJSONObjectScannerHandlesPrettyJSONAndEscapedBraces() {
        var decoder = AnalysisEngine.JSONObjectStream()
        XCTAssertTrue(decoder.append("```json\n{\n \"id\": \"b1\", \"zh\": ").isEmpty)
        let records = decoder.append("\"中文 {字符串} 与 \\\"引号\\\"\"\n}\n```\n{\"methods\":[]}")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(AnalysisEngine.parseJSON(records[0])["id"] as? String, "b1")
        XCTAssertNotNil(AnalysisEngine.parseJSON(records[1])["methods"])
    }

    func testLocalNodeRepairPreservesUnescapedQuotesAndLatexWithoutGeneration() {
        let raw = #"{"id":"b1","zh":"这里的"结构相似"与 $\alpha$ 保留原义。","note":"说明"结构相似"","role":"方法设计"}"#
        let parsed = AnalysisEngine.parseAnalysisRecord(raw)
        XCTAssertEqual(parsed["id"] as? String, "b1")
        XCTAssertEqual(parsed["zh"] as? String, #"这里的"结构相似"与 $\alpha$ 保留原义。"#)
        XCTAssertEqual(parsed["note"] as? String, #"说明"结构相似""#)
        XCTAssertEqual(parsed["role"] as? String, "方法设计")
        XCTAssertTrue(AnalysisEngine.parseAnalysisRecord(#"{"id":"b1","zh":"缺少要点"}"#).isEmpty == false)
        // Strict decoding still rejects missing fields; syntax recovery never invents them.
        XCTAssertThrowsError(try AnalysisEngine.validatePaperAnalysis(records: [parsed], input: [["id": "b1", "kind": "paragraph", "text": "Source"]]))
    }

    func testKeyedNodesPreserveNonconsecutiveSourceIDsAndRestoreSourceOrder() throws {
        let input: [[String: Any]] = [
            ["id": "source-1", "kind": "paragraph", "text_original": "First"],
            ["id": "source-6", "kind": "paragraph", "text_original": "Second"],
            ["id": "source-8", "kind": "paragraph", "text_original": "Third"]
        ]
        let raw = #"{"paper":{"narrative_summary":"全文总结","contributions":["贡献"]},"methods":[],"nodes":{"source-8":{"zh":"第三段","note":"第三个要点","role":"结论"},"source-1":{"zh":"第一段","note":"第一个要点","role":"背景"},"source-6":{"zh":"第二段","note":"第二个要点","role":"方法"}}}"#
        let result = try AnalysisEngine.decodePaperResponse(raw, blocks: input)
        XCTAssertEqual(result.nodes.compactMap { $0["id"] as? String }, ["source-1", "source-6", "source-8"])
        XCTAssertEqual(result.nodes.compactMap { $0["zh"] as? String }, ["第一段", "第二段", "第三段"])
        var decoder = AnalysisEngine.JSONObjectStream(includeNestedNodes: true)
        let records = raw.map { decoder.append(String($0)) }.flatMap { $0 }.map(AnalysisEngine.parseAnalysisRecord)
        XCTAssertEqual(records.compactMap { $0["id"] as? String }, ["source-8", "source-1", "source-6"])
    }

    func testKeyedNodesRejectMissingDuplicateAndConflictingIDs() {
        let input: [[String: Any]] = [["id": "b1", "kind": "paragraph", "text_original": "Source"]]
        let node = #"{"zh":"译文","note":"要点","role":"方法"}"#
        let prefix = #"{"paper":{"narrative_summary":"总结","contributions":["贡献"]},"methods":[],"nodes":{"#
        for raw in [prefix + "}}", prefix + "\"b1\":" + node + ",\"b1\":" + node + "}}",
                    prefix + #""b1":{"id":"wrong","zh":"译文","note":"要点","role":"方法"}}}"#] {
            XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(raw, blocks: input))
        }
    }

    func testSourceAnchorsRejectCompleteButShiftedTranslations() throws {
        let input: [[String: Any]] = [
            ["id": "b1", "kind": "paragraph", "text_original": "First paragraph"],
            ["id": "b2", "kind": "figure", "caption_original": "Fig. 5 | Survival prediction"]
        ]
        let valid = #"{"nodes":{"b1":{"source_start":"First paragraph","zh":"第一段","note":"第一要点","role":"背景"},"b2":{"source_start":"Fig. 5 | Survival prediction","zh":"图5生存预测","note":"生存预测结果","role":"验证"}},"paper":{"narrative_summary":"全文总结","contributions":["贡献"]},"methods":[]}"#
        XCTAssertNoThrow(try AnalysisEngine.decodePaperResponse(valid, blocks: input, requireSourceAnchors: true))
        let shifted = valid.replacingOccurrences(of: #""source_start":"Fig. 5 | Survival prediction""#, with: #""source_start":"First paragraph""#)
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(shifted, blocks: input, requireSourceAnchors: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("原文片段与编号不对应"))
        }
        let absent = valid.replacingOccurrences(of: #""source_start":"First paragraph","#, with: "")
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(absent, blocks: input, requireSourceAnchors: true))
        XCTAssertNoThrow(try AnalysisEngine.decodePaperResponse(absent, blocks: input))
        let brokenQuote = valid.replacingOccurrences(of: "第一段", with: #"第一段含"引号""#)
        XCTAssertNoThrow(try AnalysisEngine.decodePaperResponse(brokenQuote, blocks: input, requireSourceAnchors: true))
    }

    func testLongCaptionCannotBeReplacedWithShortParagraphOrHeading() {
        let input: [[String: Any]] = [["id": "b1", "kind": "figure", "caption_original": String(repeating: "The figure evaluates patient survival. ", count: 30)]]
        let raw = #"{"nodes":{"b1":{"zh":"模型在小型队列上表现良好，这可能反映了有限的数据。","note":"队列泛化","role":"结果"}},"paper":{"narrative_summary":"全文总结","contributions":["贡献"]},"methods":[]}"#
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(raw, blocks: input)) { error in
            XCTAssertTrue(error.localizedDescription.contains("译文远短于原文"))
        }
    }

    func testStreamingSourceMismatchStopsWithoutRetry() async throws {
        for mode in ["sourceMismatch", "missingSource"] {
            SingleAnalysisProtocol.reset(mode)
            let log = CaptureLog()
            do {
                _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session(), capture: { await log.save($0) })
                XCTFail("Source mismatch must fail")
            } catch { XCTAssertTrue(error.localizedDescription.contains("原文片段与编号不对应")) }
            XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
            let captured = await log.value
            XCTAssertFalse((captured["raw_response"] as? String ?? "").isEmpty)
        }
    }

    func testArrayWrappedKeyedNodesUseOnlyExplicitIDs() throws {
        let input: [[String: Any]] = [
            ["id": "b1", "kind": "paragraph", "text_original": "First"],
            ["id": "b6", "kind": "paragraph", "text_original": "Second"]
        ]
        let raw = #"{"nodes":[{"b6":{"zh":"第二段","note":"第二要点","role":"方法"}},{"b1":{"zh":"第一段","note":"第一要点","role":"背景"}}],"paper":{"narrative_summary":"全文总结","contributions":["贡献"]},"methods":[]}"#
        let result = try AnalysisEngine.decodePaperResponse(raw, blocks: input)
        XCTAssertEqual(result.nodes.compactMap { $0["id"] as? String }, ["b1", "b6"])
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(raw.replacingOccurrences(of: "b6", with: "b1"), blocks: input))
    }

    func testMalformedOuterKeyedContainerRecoversOnlyCompleteNamedValues() throws {
        let input: [[String: Any]] = [
            ["id": "b1", "kind": "paragraph", "text_original": "First"],
            ["id": "b6", "kind": "paragraph", "text_original": "Second"]
        ]
        // Real model failure: opens an extra brace at each next keyed node.
        let raw = #"{"nodes":{"b1":{"zh":"第一段","note":"第一要点","role":"背景"},{"b6":{"zh":"第二段","note":"第二要点","role":"方法"}},"paper":{"narrative_summary":"全文总结","contributions":["贡献"]},"methods":[{"name":"Model","refs":["b6"]}]}"#
        let result = try AnalysisEngine.decodePaperResponse(raw, blocks: input)
        XCTAssertEqual(result.nodes.compactMap { $0["zh"] as? String }, ["第一段", "第二段"])
        XCTAssertEqual(result.methods.first?["refs"] as? [String], ["b6"])
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(String(raw.dropLast(3)), blocks: input))
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(raw.replacingOccurrences(of: "b6", with: "b1"), blocks: input))
    }

    func testKeyedQuoteRepairPreservesTranslationAndFollowingNodes() throws {
        let input: [[String: Any]] = [
            ["id": "b1", "kind": "paragraph", "text_original": "First"],
            ["id": "b6", "kind": "paragraph", "text_original": "Second"]
        ]
        let raw = #"{"nodes":{"b1":{"zh":"得到产物 4"。原文与 $\alpha$ 保留。","note":"带引号的译文","role":"背景"},"b6":{"zh":"完整下一段","note":"下一要点","role":"方法"}},"paper":{"narrative_summary":"全文总结","contributions":["贡献"]},"methods":[]}"#
        let result = try AnalysisEngine.decodePaperResponse(raw, blocks: input)
        XCTAssertEqual(result.nodes[0]["zh"] as? String, #"得到产物 4"。原文与 $\alpha$ 保留。"#)
        XCTAssertEqual(result.nodes[1]["zh"] as? String, "完整下一段")
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(raw.replacingOccurrences(of: #","role":"方法""#, with: ""), blocks: input))
    }

    func testOutputStallDetectsWhitespaceWithoutRejectingNormalTranslation() throws {
        XCTAssertThrowsError(try AnalysisEngine.checkOutputStall("{\"nodes\":{" + String(repeating: "\t", count: 2048)))
        XCTAssertNoThrow(try AnalysisEngine.checkOutputStall(String(repeating: "正常译文 ", count: 1000)))
        XCTAssertNoThrow(try AnalysisEngine.checkOutputStall("{\n  \"nodes\": {\n"))
    }

    func testStreamingWhitespaceFailureKeepsResponseAndDoesNotRetry() async throws {
        SingleAnalysisProtocol.reset("whitespace")
        let log = CaptureLog()
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session(), capture: { await log.save($0) })
            XCTFail("Stalled output must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("空白")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
        let captured = await log.value
        XCTAssertTrue((captured["raw_response"] as? String ?? "").hasSuffix(String(repeating: "\t", count: 2048)))
    }

    func testStreamingMethodLoopStopsAndRetainsResponseWithoutRetry() async throws {
        SingleAnalysisProtocol.reset("methodLoop")
        let log = CaptureLog()
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session(), capture: { await log.save($0) })
            XCTFail("Repeated catalog output must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("反复输出")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
        let captured = await log.value
        XCTAssertTrue((captured["raw_response"] as? String ?? "").contains("Copied method"))
    }

    func testMethodsAfterReferencesAreAnalyzedAndMissingLateMethodsCannotRecover() async throws {
        SingleAnalysisProtocol.reset()
        let input: [[String: Any]] = [
            ["id": "body", "kind": "paragraph", "text_original": "Scientific summary"],
            ["id": "refs", "kind": "section_heading", "text_original": "References"],
            ["id": "ref-1", "kind": "paragraph", "text_original": "Citation"],
            ["id": "methods", "kind": "section_heading", "text_original": "Methods"],
            ["id": "protocol", "kind": "paragraph", "text_original": "Complete protocol"],
            ["id": "data", "kind": "section_heading", "text_original": "Data availability"]
        ]
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: input, title: "test", session: session())
        XCTAssertEqual(SingleAnalysisProtocol.seenBlocks.compactMap { $0["id"] as? String }, ["body", "methods", "protocol"])
        XCTAssertEqual(result.nodes[4]["zh"] as? String, "完整中文翻译")
        let old = #"{"paper":{"narrative_summary":"旧总结","contributions":["贡献"]},"methods":[],"nodes":[{"id":"body","zh":"旧译文","note":"要点","role":"背景"}]}"#
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(old, blocks: input))
    }

    func testFigurePanelLabelsStayLocalAndDoNotRenumberScientificContent() async throws {
        SingleAnalysisProtocol.reset()
        let input: [[String: Any]] = [
            ["id": "panel-1", "kind": "figure", "caption_original": "a"],
            ["id": "image-2", "kind": "figure", "caption_original": ""],
            ["id": "science-6", "kind": "paragraph", "text_original": "Scientific evidence"]
        ]
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: input, title: "test", session: session())
        XCTAssertEqual(SingleAnalysisProtocol.seenBlocks.compactMap { $0["id"] as? String }, ["science-6"])
        XCTAssertEqual(result.nodes.compactMap { $0["id"] as? String }, ["panel-1", "image-2", "science-6"])
        XCTAssertEqual(result.nodes[0]["zh"] as? String, "a")
        XCTAssertEqual(result.nodes[1]["note"] as? String, "无图注，请查看原图")
    }

    func testLongParagraphCannotBeReplacedByHeadingOrPanelLabel() {
        let input: [[String: Any]] = [["id": "b1", "kind": "paragraph", "text_original": String(repeating: "Detailed scientific source. ", count: 12)]]
        for translation in ["4 实验", "b"] {
            let raw = AnalysisEngine.jsonString(["nodes": ["b1": ["zh": translation, "note": "要点", "role": "正文"]],
                                                "paper": ["narrative_summary": "全文总结", "contributions": ["贡献"]], "methods": []])
            XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(raw, blocks: input)) { error in
                XCTAssertTrue(error.localizedDescription.contains("译文不完整"))
            }
        }
    }

    func testInputFingerprintTracksSourceChangesButIgnoresDictionaryOrder() {
        let first: [[String: Any]] = [["id": "b1", "kind": "paragraph", "text_original": "English source"]]
        let same: [[String: Any]] = [["text_original": "English source", "kind": "paragraph", "id": "b1"]]
        let changed: [[String: Any]] = [["id": "b1", "kind": "paragraph", "text_original": "Changed source"]]
        XCTAssertEqual(AnalysisEngine.inputFingerprint(first), AnalysisEngine.inputFingerprint(same))
        XCTAssertNotEqual(AnalysisEngine.inputFingerprint(first), AnalysisEngine.inputFingerprint(changed))
    }

    func testJSONFallbackNeverIndexesAbsentRegexCaptureGroup() {
        XCTAssertEqual(AnalysisEngine.parseJSON("prefix {\"ok\":true} suffix")["ok"] as? Bool, true)
        XCTAssertTrue(AnalysisEngine.parseJSON("{invalid}").isEmpty)
        XCTAssertTrue(AnalysisEngine.parseJSON("\"paper\": {invalid}").isEmpty)
        XCTAssertTrue(AnalysisEngine.parseJSON("{partial").isEmpty)
    }

    func testAllBlocksShareOneStreamingGenerationAndProgress() async throws {
        SingleAnalysisProtocol.reset()
        let log = CaptureLog()
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session(),
            progress: { done, _ in await log.step(done) }, capture: { await log.save($0) })
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
        XCTAssertEqual(SingleAnalysisProtocol.seenBlocks.count, 25)
        XCTAssertEqual(SingleAnalysisProtocol.seenBlocks.last?["text"] as? String, "Original full paragraph 24")
        XCTAssertEqual(result.nodes.count, 25)
        XCTAssertEqual(result.methods.first?["refs"] as? [String], ["original-0"])
        let progress = await log.progress
        XCTAssertEqual(progress.first, 0); XCTAssertEqual(progress.last, 25)
        XCTAssertGreaterThan(progress.count, 2)
        let captured = await log.value
        XCTAssertEqual(captured["completion_requests"] as? Int, 1)
    }

    func testReferencesStayLocalAndAllNodesRemainInOriginalOrder() async throws {
        SingleAnalysisProtocol.reset()
        let input: [[String: Any]] = [
            ["id": "body-1", "kind": "paragraph", "text_original": "Scientific body"],
            ["id": "refs", "kind": "section_heading", "text_original": "References"],
            ["id": "ref-1", "kind": "paragraph", "text_original": "1. Author. Original English title. Journal 2026."],
            ["id": "after", "kind": "section_heading", "text_original": "Author contributions"],
            ["id": "body-2", "kind": "paragraph", "text_original": "Additional text"]
        ]
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: input, title: "test", session: session())
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
        XCTAssertEqual(SingleAnalysisProtocol.seenBlocks.count, 1)
        XCTAssertEqual(result.nodes.compactMap { $0["id"] as? String }, ["body-1", "refs", "ref-1", "after", "body-2"])
        XCTAssertEqual(result.nodes[2]["zh"] as? String, "")
        XCTAssertEqual(result.nodes[2]["role"] as? String, "")
        XCTAssertEqual(result.nodes[4]["zh"] as? String, "")
    }

    func testAnalysisReceivesAllCurrentGroupsAndExistingMethods() async throws {
        SingleAnalysisProtocol.reset("customGroup")
        let groups = [MethodGroup(id: "custom_group", name: "用户自定义类别"), MethodGroup(id: "METRIC", name: "已改名的空类别")]
        let existing = [MethodIndexItem(canonicalKey: "known", name: "Known", category: "custom_group", definitionZh: "已有方法说明", papers: [])]
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", methodGroups: groups, existingMethods: existing, session: session())
        XCTAssertEqual((SingleAnalysisProtocol.seenCatalog["groups"] as? [[String: String]])?.map { $0["name"]! }, groups.map(\.name))
        XCTAssertEqual((SingleAnalysisProtocol.seenCatalog["existing_methods"] as? [[String: String]])?.first?["key"], "known")
        XCTAssertEqual(result.methods.first?["category"] as? String, "custom_group")
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
    }

    func testMethodSuggestionsPreserveEditedNameMovedGroupAndEvidence() throws {
        let groups = [MethodGroup(id: "custom", name: "自定义分组")]
        let existing = [MethodIndexItem(canonicalKey: "stable_key", name: "Edited Name", category: "custom", definitionZh: "用户说明", papers: [])]
        let methods: [[String: Any]] = [
            ["name": "Full synonym", "category": "ML_MODEL", "existing_key": "stable_key", "refs": ["b1"]],
            ["name": "Edited Name", "category": "OTHER", "refs": ["b2"]]
        ]
        let result = try AnalysisEngine.resolveMethods(methods, groups: groups, existing: existing)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0]["canonical_key"] as? String, "stable_key")
        XCTAssertEqual(result[0]["name"] as? String, "Edited Name")
        XCTAssertEqual(result[0]["category"] as? String, "custom")
        XCTAssertEqual(result[0]["refs"] as? [String], ["b1", "b2"])
    }

    func testSharedCategoryDoesNotMergeDifferentMethodsAndUnknownCatalogIdsFail() throws {
        let groups = [MethodGroup(id: "custom", name: "自定义分组")]
        let existing = [MethodIndexItem(canonicalKey: "known", name: "Known", category: "custom", definitionZh: "用户说明", papers: [])]
        let fresh: [String: Any] = ["name": "Different", "category": "custom", "refs": ["b1"]]
        let result = try AnalysisEngine.resolveMethods([fresh], groups: groups, existing: existing)
        XCTAssertEqual(result.first?["canonical_key"] as? String, "different")
        XCTAssertThrowsError(try AnalysisEngine.resolveMethods([["name": "New", "category": "deleted"]], groups: groups, existing: existing))
        XCTAssertThrowsError(try AnalysisEngine.resolveMethods([["name": "New", "category": "custom", "existing_key": "invented"]], groups: groups, existing: existing))
    }

    func testFrontMatterNeverEntersModelRequest() async throws {
        SingleAnalysisProtocol.reset()
        let input: [[String: Any]] = [
            ["id": "title", "kind": "section_heading", "text_original": "Document title"],
            ["id": "author", "kind": "paragraph", "text_original": "Author and affiliations"],
            ["id": "abstract", "kind": "section_heading", "text_original": "Abstract"],
            ["id": "body", "kind": "paragraph", "text_original": "Scientific summary"],
            ["id": "references", "kind": "section_heading", "text_original": "References"]
        ]
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: input, title: "test", session: session())
        XCTAssertEqual(SingleAnalysisProtocol.seenBlocks.compactMap { $0["id"] as? String }, ["abstract", "body"])
        XCTAssertEqual(result.nodes.count, 5)
        XCTAssertEqual(result.nodes[0]["zh"] as? String, "")
        XCTAssertEqual(result.nodes[1]["zh"] as? String, "")
        XCTAssertEqual(result.nodes[4]["zh"] as? String, "")
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
    }

    func testNonStreamingAlsoUsesExactlyOneGeneration() async throws {
        SingleAnalysisProtocol.reset()
        let result = try await AnalysisEngine.analyzePaper(llm: llm(false), blocks: blocks(), title: "test", session: session())
        XCTAssertEqual(result.nodes.count, 25); XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
    }

    func testPartialResponseIsSavedWithoutPaidRecoveryCalls() async throws {
        SingleAnalysisProtocol.reset("missing")
        let log = CaptureLog()
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session(), capture: { await log.save($0) })
            XCTFail("Incomplete analysis must not become ready")
        } catch { XCTAssertTrue(error.localizedDescription.contains("24 / 25")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
        let captured = await log.value
        XCTAssertTrue((captured["raw_response"] as? String ?? "").contains("original-23"))
    }

    func testOutputBudgetUsesProviderOutputLimitNotContextWindow() async throws {
        SingleAnalysisProtocol.reset()
        let input: [[String: Any]] = [["id": "original-0", "kind": "paragraph", "text_original": String(repeating: "English ", count: 20_000)]]
        _ = try await AnalysisEngine.analyzeSinglePass(llm: llm(), blocks: input, title: "test", session: session())
        XCTAssertEqual(SingleAnalysisProtocol.requestedBudget, 32768)
    }

    func testLongPaperUsesBoundedTranslationAndOneGlobalAnalysis() async throws {
        SingleAnalysisProtocol.reset()
        var input = blocks(80)
        input.insert(contentsOf: [
            ["id": "refs", "kind": "section_heading", "text_original": "References", "section_title": "References"],
            ["id": "ref-1", "kind": "paragraph", "text_original": "1. Author. Journal 2026.", "section_title": "References"]
        ], at: 40)
        let log = CaptureLog()
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: input, title: "test", session: session(), capture: { await log.save($0) })
        XCTAssertEqual(result.nodes.count, 82)
        XCTAssertEqual(result.nodes.compactMap { $0["id"] as? String }, input.compactMap { $0["id"] as? String })
        XCTAssertEqual(SingleAnalysisProtocol.translationBatches.count, 5)
        XCTAssertTrue(SingleAnalysisProtocol.translationBatches.allSatisfy { $0.count <= 16 })
        XCTAssertEqual(SingleAnalysisProtocol.translationBatches.flatMap { $0 }, blocks(80).compactMap { $0["id"] as? String })
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 6)
        let saved = await log.value
        XCTAssertEqual(saved["mode"] as? String, "bounded_batches")
        XCTAssertEqual(saved["state"] as? String, "complete")
        XCTAssertEqual((saved["batch_responses"] as? [[String: Any]])?.count, 5)
        XCTAssertNoThrow(try AnalysisEngine.decodePaperResponse(saved["raw_response"] as! String, blocks: input, requireSourceAnchors: true))
    }

    func testFailedTranslationBatchRetainsCompletedWorkAndNeverRetries() async throws {
        SingleAnalysisProtocol.reset("missingSecondBatch")
        let log = CaptureLog()
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(80), title: "test", session: session(), capture: { await log.save($0) })
            XCTFail("Missing node must stop the paper")
        } catch { XCTAssertTrue(error.localizedDescription.contains("完整性不符")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 2)
        let saved = await log.value
        XCTAssertEqual(saved["state"] as? String, "failed")
        XCTAssertEqual(saved["completed_batches"] as? Int, 1)
        XCTAssertEqual((saved["batch_responses"] as? [[String: Any]])?.count, 2)
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(saved["raw_response"] as! String, blocks: blocks(80)))
    }

    func testFormulaAnchorHasNoJSONEscapesAndIsStable() {
        let formula = #"$$\mathrm{TPM}_{i} = \frac{\mathrm{RPK}_{i}}{\sum_{j=1}^{N}\mathrm{RPK}_{j}}$$"#
        let anchor = AnalysisEngine.sourceAnchor(formula)
        XCTAssertFalse(anchor.contains("\\"))
        XCTAssertEqual(AnalysisEngine.sourceAnchor(anchor), anchor)
        XCTAssertTrue(anchor.contains("TPM"))
    }

    func testInvalidGlobalEvidenceKeepsTranslationsButCannotBecomeReady() async throws {
        SingleAnalysisProtocol.reset("badRef")
        let log = CaptureLog()
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(80), title: "test", session: session(), capture: { await log.save($0) })
            XCTFail("Invalid evidence must fail global analysis")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无效的原文引用")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 6)
        let saved = await log.value
        XCTAssertEqual(saved["completed_nodes"] as? Int, 80)
        XCTAssertEqual(saved["state"] as? String, "failed")
        XCTAssertFalse((saved["metadata_response"] as? String ?? "").isEmpty)
        XCTAssertThrowsError(try AnalysisEngine.decodePaperResponse(saved["raw_response"] as! String, blocks: blocks(80)))
    }

    func testManualResumeReusesOnlyCompleteValidatedTranslationChunks() async throws {
        SingleAnalysisProtocol.reset("missingSecondBatch")
        let first = CaptureLog()
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(80), title: "test", session: session(), capture: { await first.save($0) })
            XCTFail("Expected incomplete second batch")
        } catch {}
        let partial = await first.value
        SingleAnalysisProtocol.reset()
        let second = CaptureLog()
        let result = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(80), title: "test", resumeLog: partial,
            session: session(), capture: { await second.save($0) })
        XCTAssertEqual(result.nodes.count, 80)
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 5)
        XCTAssertEqual(SingleAnalysisProtocol.translationBatches.first?.first, "original-16")
        let saved = await second.value
        XCTAssertEqual(saved["reused_batches"] as? Int, 1)
        XCTAssertEqual(saved["completion_requests"] as? Int, 5)
        SingleAnalysisProtocol.reset()
        var changed = blocks(80); changed[0]["text_original"] = "Changed source paragraph"
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: changed, title: "test", resumeLog: partial, session: session())
            XCTFail("Changed original must not reuse saved translations")
        } catch { XCTAssertTrue(error.localizedDescription.contains("原文或分段范围已变化")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 0)
    }

    func testQwenTranslationDisablesThinkingForStreamingAndChat() async throws {
        for streaming in [true, false] {
            SingleAnalysisProtocol.reset()
            var config = llm(streaming); config.model = "Qwen3.5-122B-A10B-NVFP4"; config.reasoningEffort = "high"
            let result = try await AnalysisEngine.analyzePaper(llm: config, blocks: blocks(), title: "test", session: session())
            XCTAssertEqual(result.nodes.count, 25)
            XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
        }
        XCTAssertEqual(LLMClient.reasoningFields("high", model: "Qwen3.5", baseURL: "http://localhost/v1")["reasoning_effort"] as? String, "high")
        XCTAssertEqual(LLMClient.reasoningFields("none", model: "qwen3.5-plus", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")["enable_thinking"] as? Bool, false)
        XCTAssertEqual(LLMClient.reasoningFields("none", model: "kimi-k2.5", baseURL: "https://api.kimi.com/v1")["reasoning_effort"] as? String, "none")
    }

    func testHTTPFailureSurfacesWithNoRetries() async throws {
        SingleAnalysisProtocol.reset("denied")
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session())
            XCTFail("Expected HTTP 401")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 401")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
    }

    func testTokenTruncationNeverBecomesSuccess() async throws {
        SingleAnalysisProtocol.reset("length")
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session())
            XCTFail("Expected token truncation error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("截断")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
    }

    func testMethodReferencesCannotInventBlockIDs() async throws {
        SingleAnalysisProtocol.reset("badRef")
        do {
            _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: blocks(), title: "test", session: session())
            XCTFail("Expected invalid reference")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无效的原文引用")) }
        XCTAssertEqual(SingleAnalysisProtocol.completionCount, 1)
    }
}
