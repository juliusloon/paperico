import XCTest
@testable import PapericoCore

@MainActor
final class ChatAgentTests: XCTestCase {
    private func events(_ events: [LLMAgentEvent]) -> AsyncThrowingStream<LLMAgentEvent, Error> {
        AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
    private var llm: AnalysisEngine.LLMConfig {
        .init(baseURL: "https://test.invalid", apiKey: "test", model: "test", reasoningEffort: nil, supportsTools: true)
    }
    func testZeroOneThreeRoundsAndCallLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root); try await library.load()
        for requestedRounds in [0, 1, 3] {
            let agent = ChatAgent(registry: .init(), executor: .init(library: library, papers: [], methods: []), llm: llm)
            var rounds = 0, answer = ""
            for try await chunk in agent.response(messages: [], response: { _, tools, _ in
                defer { rounds += 1 }
                if rounds < requestedRounds && !tools.isEmpty {
                    return self.events([.content("hidden intermediate"), .toolCallDelta(index: 0, id: "call\(rounds)", name: "search_library", arguments: "{\"query\":\"test\"}"), .finishReason("tool_calls")])
                }
                return self.events([.content("final answer"), .finishReason("stop")])
            }, activity: { _ in }) { answer += chunk }
            XCTAssertEqual(answer, "final answer")
            XCTAssertEqual(agent.toolRounds, requestedRounds)
            XCTAssertEqual(agent.toolCalls, requestedRounds)
            XCTAssertEqual(rounds, requestedRounds + 1)
        }
        let agent = ChatAgent(registry: .init(), executor: .init(library: library, papers: [], methods: []), llm: llm)
        var requests = 0
        for try await _ in agent.response(messages: [], response: { _, tools, _ in
            requests += 1
            if tools.isEmpty { return self.events([.content("budget final"), .finishReason("stop")]) }
            return self.events((0..<10).map { .toolCallDelta(index: $0, id: "c\($0)", name: "unknown_tool", arguments: "{}") } + [.finishReason("tool_calls")])
        }, activity: { _ in }) {}
        XCTAssertEqual(agent.toolCalls, 8)
        XCTAssertEqual(requests, 2)
        XCTAssertLessThanOrEqual(agent.usedCharacters, 24_000)
    }
    func testPrivacyDefaultOffAndFallbackMakesOneGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root); try await library.load()
        let current = try await library.importPDF(fileData: Data("%PDF-1.7\ncurrent".utf8), fileName: "current.pdf", projectId: nil)
        _ = try await library.importPDF(fileData: Data("%PDF-1.7\nother".utf8), fileName: "other.pdf", projectId: nil, metadata: .init(title: "UniqueContrastiveTitle"))
        var count = 0
        for try await _ in ChatService.send(paperId: current.id, content: "UniqueContrastiveTitle", sessionId: nil, attachedContext: nil,
            library: library, llm: llm, response: { messages, _ in
                count += 1
                XCTAssertFalse((messages[0]["content"] as? String ?? "").contains("UniqueContrastiveTitle"))
                return AsyncThrowingStream { $0.yield("single paper answer"); $0.finish() }
            }, agentResponse: { _, _, _ in XCTFail("Default privacy must not send tools"); return self.events([]) }) {}
        XCTAssertEqual(count, 1)
        var fallback = llm; fallback.supportsTools = nil
        count = 0
        for try await _ in ChatService.send(paperId: current.id, content: "UniqueContrastiveTitle", sessionId: nil, attachedContext: nil,
            library: library, llm: fallback, response: { messages, _ in
                count += 1
                XCTAssertTrue((messages[0]["content"] as? String ?? "").contains("UniqueContrastiveTitle"))
                return AsyncThrowingStream { $0.yield("answer [s001]"); $0.finish() }
            }, allowLibraryContext: true) {}
        XCTAssertEqual(count, 1)
        let sessions = try await library.chatSessions(paperId: current.id)
        XCTAssertTrue(sessions.contains { $0.messages.contains { $0.sourceRefs?.first?.kind == .paper } })
    }
    func testCancelledAgentExecutesNoLaterRounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root); try await library.load()
        let agent = ChatAgent(registry: .init(), executor: .init(library: library, papers: [], methods: []), llm: llm)
        var requests = 0
        let task = Task {
            for try await _ in agent.response(messages: [], response: { _, _, _ in
                requests += 1
                return AsyncThrowingStream { continuation in
                    let producer = Task {
                        do { try await Task.sleep(nanoseconds: 10_000_000_000); continuation.finish() }
                        catch { continuation.finish(throwing: error) }
                    }
                    continuation.onTermination = { _ in producer.cancel() }
                }
            }, activity: { _ in }) {}
        }
        await Task.yield(); task.cancel()
        _ = try? await task.value
        XCTAssertLessThanOrEqual(requests, 1)
        XCTAssertEqual(agent.toolCalls, 0)
    }
    func testAgentPersistsOnlyVisibleAnswerAndRegisteredSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root); try await library.load()
        let current = try await library.importPDF(fileData: Data("%PDF-1.7\nsource".utf8), fileName: "source.pdf", projectId: nil)
        let other = try await library.importPDF(fileData: Data("%PDF-1.7\nevidence".utf8), fileName: "evidence.pdf", projectId: nil)
        var requests = 0, answer = ""
        for try await event in ChatService.send(paperId: current.id, content: "read evidence", sessionId: nil, attachedContext: nil,
            library: library, llm: llm, allowLibraryContext: true, agentResponse: { messages, tools, _ in
                requests += 1
                XCTAssertFalse(tools.isEmpty)
                if requests == 1 {
                    return self.events([.content("private intermediate"), .toolCallDelta(index: 0, id: "read", name: "get_paper", arguments: AnalysisEngine.jsonString(["paper_id": other.id])), .finishReason("tool_calls")])
                }
                XCTAssertEqual(messages.last?["role"] as? String, "tool")
                XCTAssertTrue((messages.last?["content"] as? String ?? "").contains("s001"))
                return self.events([.content("answer [s001] [s999]"), .finishReason("stop")])
            }) { answer += event.content ?? "" }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(answer, "answer [s001] [s999]")
        let session = try await library.chatSessions(paperId: current.id).first!
        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages.last?.sourceRefs?.map(\.paperId), [other.id])
        XCTAssertFalse(session.messages.contains { $0.content.contains("private intermediate") })
        let unchanged = await library.paper(id: other.id)
        XCTAssertNil(unchanged?.lastOpenedAt)
    }
    func testToolsRejectionFailsOnceWithoutHiddenFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root); try await library.load()
        let current = try await library.importPDF(fileData: Data("%PDF-1.7\nreject".utf8), fileName: "reject.pdf", projectId: nil)
        var requests = 0, invalidated = false
        do {
            for try await _ in ChatService.send(paperId: current.id, content: "test", sessionId: nil, attachedContext: nil,
                library: library, llm: llm, response: { _, _ in XCTFail("No hidden fallback"); return AsyncThrowingStream { $0.finish() } },
                allowLibraryContext: true, agentResponse: { _, _, _ in
                    requests += 1
                    return AsyncThrowingStream { $0.finish(throwing: LLMServiceError("HTTP 400: unsupported tools")) }
                }, onToolsRejected: { invalidated = true }) {}
            XCTFail("Tools rejection must fail the turn")
        } catch { XCTAssertTrue(ChatAgent.isToolsRejection(error)) }
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(invalidated)
        let session = try await library.chatSessions(paperId: current.id).first!
        XCTAssertEqual(session.messages.last?.generationState, "failed")
    }

}
