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
}
