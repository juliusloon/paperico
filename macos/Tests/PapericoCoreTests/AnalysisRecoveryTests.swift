import Foundation
import XCTest
@testable import PapericoCore

private final class SingleAnalysisProtocol: URLProtocol {
    static let lock = NSLock()
    static var completionCount = 0
    static var seenBlocks: [[String: Any]] = []
    static var requestedBudget = 0
    static var mode = "complete"

    static func reset(_ mode: String = "complete") {
        lock.lock(); defer { lock.unlock() }
        completionCount = 0; seenBlocks = []; requestedBudget = 0; self.mode = mode
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
        XCTAssertEqual((payload["response_format"] as? [String: String])?["type"], "json_object")
        XCTAssertEqual(payload["reasoning_effort"] as? String, "low")
        let messages = payload["messages"] as! [[String: Any]]
        let content = messages.last!["content"] as! String
        let input = try! JSONSerialization.jsonObject(with: Data(content.components(separatedBy: .newlines).last!.utf8)) as! [[String: Any]]
        Self.lock.lock()
        Self.completionCount += 1; Self.seenBlocks = input; Self.requestedBudget = payload["max_tokens"] as! Int
        let mode = Self.mode
        Self.lock.unlock()
        if mode == "denied" {
            respond(status: 401, data: Data(#"{"error":{"message":"invalid test key"}}"#.utf8)); return
        }
        let paper: [String: Any] = ["title": "A real title", "title_zh": "中文标题", "tldr": "核心结论", "narrative_summary": "根据全文原文建立逻辑关系。", "contributions": ["新的方法"], "domain_tags": ["机器学习"], "difficulty_estimate": "中等"]
        var records: [[String: Any]] = [["paper": paper]]
        for block in (mode == "missing" ? Array(input.dropLast()) : input) {
            records.append(["id": block["id"]!, "zh": "完整中文翻译", "note": "具体中文要点", "role": "方法设计"])
        }
        records.append(["methods": [["name": "Graph model", "category": "ML_MODEL", "definition_zh": "学习分子性质", "refs": [mode == "badRef" ? "invented-id" : input.first!["id"]!]]]])
        let document: [String: Any] = ["paper": paper, "methods": records.last!["methods"]!, "nodes": Array(records.dropFirst().dropLast())]
        let lines = AnalysisEngine.jsonString(document)
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
        _ = try await AnalysisEngine.analyzePaper(llm: llm(), blocks: input, title: "test", session: session())
        XCTAssertEqual(SingleAnalysisProtocol.requestedBudget, 32768)
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
