import XCTest
@testable import PapericoCore

final class ChatServiceTests: XCTestCase {
    func testTitleDecoderHandlesSplitTagsAndPreservesOrdinaryAnswers() {
        let wire = "\n<paperico-title> 活性悬崖 机制 </paperico-title>\n\n证据 [b001]"
        var decoder = ChatTitleDecoder(enabled: true)
        var answer = "", title: String?
        for character in wire {
            let decoded = decoder.append(String(character))
            title = decoded.title ?? title; answer += decoded.content
        }
        answer += decoder.finish()
        XCTAssertEqual(title, "活性悬崖 机制")
        XCTAssertEqual(answer.trimmingCharacters(in: .whitespacesAndNewlines), "证据 [b001]")

        for text in ["普通回答", "<p>回答</p>", "\n回答 **保留格式**"] {
            var fallback = ChatTitleDecoder(enabled: true)
            let result = fallback.append(text)
            XCTAssertNil(result.title)
            XCTAssertEqual(result.content + fallback.finish(), text)
        }
        for partial in ["<paperico-title>未完成", "\n<paperico-ti"] {
            var interrupted = ChatTitleDecoder(enabled: true)
            XCTAssertEqual(interrupted.append(partial).content, "")
            XCTAssertEqual(interrupted.finish(), "")
        }
        var existing = ChatTitleDecoder(enabled: false)
        XCTAssertEqual(existing.append(wire).content, wire)
    }

    @MainActor
    func testTitleGeneratedAlongsideAnswerIsPersistedAndOnlyRequestedForFirstTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\ntest".utf8), fileName: "test.pdf", projectId: nil)
        let config = AnalysisEngine.LLMConfig(baseURL: "https://example.invalid", apiKey: "test", model: "fixture", reasoningEffort: nil)
        let first = ChatService.send(paperId: paper.id, content: "解释研究", sessionId: nil, attachedContext: nil,
                                     library: library, llm: config, response: { messages, _ in
            XCTAssertTrue((messages.first?["content"] as? String)?.contains("<paperico-title>") == true)
            return AsyncThrowingStream {
                $0.yield("<paperico-ti"); $0.yield("tle>模型机制</paperico-title>\n正文回答"); $0.finish()
            }
        })
        var sessionId: String?, title: String?, answer = ""
        for try await event in first {
            sessionId = event.sessionId ?? sessionId; title = event.sessionTitle ?? title
            answer += event.content ?? ""
        }
        let id = try XCTUnwrap(sessionId)
        XCTAssertEqual(title, "模型机制"); XCTAssertEqual(answer, "正文回答")
        let saved = try await library.chatSession(paperId: paper.id, sessionId: id)
        XCTAssertEqual(saved?.title, "模型机制")
        XCTAssertEqual(saved?.messages.last?.content, "正文回答")
        let next = ChatService.send(paperId: paper.id, content: "追问", sessionId: id, attachedContext: nil,
                                    library: library, llm: config, response: { messages, _ in
            XCTAssertFalse((messages.first?["content"] as? String)?.contains("<paperico-title>") == true)
            return AsyncThrowingStream { $0.yield("后续回答"); $0.finish() }
        })
        for try await _ in next {}
        let continued = try await library.chatSession(paperId: paper.id, sessionId: id)
        XCTAssertEqual(continued?.title, "模型机制")
        XCTAssertEqual(continued?.messages.count, 4)
    }

    @MainActor
    func testStoppingStreamPersistsPartialAnswerAndReturnsCanonicalSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\ntest".utf8), fileName: "test.pdf", projectId: nil)
        let config = AnalysisEngine.LLMConfig(baseURL: "https://example.invalid", apiKey: "test", model: "fixture", reasoningEffort: nil)
        var generation: Task<Void, Never>?
        var sessionId: String?
        var received = ""
        let stream = ChatService.send(paperId: paper.id, content: "解释研究", sessionId: nil, attachedContext: nil,
                                      library: library, llm: config, response: { _, _ in
            AsyncThrowingStream { continuation in
                let producer = Task {
                    continuation.yield("<paperico-title>研究问题</paperico-title>已生成的部分")
                    do { try await Task.sleep(for: .seconds(20)); continuation.yield("不应继续"); continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        }, onTask: { generation = $0 })
        do {
            for try await event in stream {
                if let id = event.sessionId { sessionId = id }
                if let text = event.content { received += text; generation?.cancel() }
            }
            XCTFail("Stopped generation must finish with cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(received, "已生成的部分")
        let id = try XCTUnwrap(sessionId)
        let saved = try await library.chatSession(paperId: paper.id, sessionId: id)
        XCTAssertEqual(saved?.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(saved?.messages.last?.content, "已生成的部分")
        XCTAssertEqual(saved?.messages.last?.generationState, "stopped")
        XCTAssertEqual(saved?.title, "研究问题")
    }

    @MainActor
    func testCompletedStreamPersistsOnceAndMissingConfigRetainsQuestion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\ntest".utf8), fileName: "test.pdf", projectId: nil)
        let config = AnalysisEngine.LLMConfig(baseURL: "https://example.invalid", apiKey: "test", model: "fixture", reasoningEffort: nil)
        let complete = ChatService.send(paperId: paper.id, content: "问题", sessionId: nil, attachedContext: nil,
                                       library: library, llm: config, response: { _, _ in
            AsyncThrowingStream { $0.yield("回答"); $0.finish() }
        })
        var sessionId: String?
        for try await event in complete { sessionId = event.sessionId ?? sessionId }
        let id = try XCTUnwrap(sessionId)
        let saved = try await library.chatSession(paperId: paper.id, sessionId: id)
        XCTAssertEqual(saved?.messages.count, 2)
        XCTAssertNil(saved?.messages.last?.generationState)

        let missing = AnalysisEngine.LLMConfig(baseURL: "", apiKey: "", model: "", reasoningEffort: nil)
        let failure = ChatService.send(paperId: paper.id, content: "保留此问题", sessionId: id, attachedContext: nil,
                                      library: library, llm: missing, response: { _, _ in
            XCTFail("Unconfigured service must never call a model"); return AsyncThrowingStream { $0.finish() }
        })
        do { for try await _ in failure {}; XCTFail("Missing configuration must fail") }
        catch { XCTAssertEqual((error as? PipelineError)?.errorCode, .llmNotConfigured) }
        let retained = try await library.chatSession(paperId: paper.id, sessionId: id)
        XCTAssertEqual(retained?.messages.last?.content, "保留此问题")
        XCTAssertEqual(retained?.messages.last?.role, "user")
    }
}
