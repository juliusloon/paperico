import XCTest
@testable import PapericoCore

private final class AgentFixtureProtocol: URLProtocol {
    static var fixture = Data()
    static var status = 200
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.fixture)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LLMAgentTransportTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AgentFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private func config(streaming: Bool) -> AnalysisEngine.LLMConfig {
        .init(baseURL: "https://fixture.test", apiKey: "test", model: "test", reasoningEffort: nil, streaming: streaming)
    }
    func testFragmentedParallelCallsAndContent() throws {
        var state = LLMAgentAccumulator()
        let chunks: [[String: Any]] = [
            ["delta": ["content": "intermediate", "tool_calls": [
                ["index": 1, "id": "b", "function": ["name": "get_blocks", "arguments": "{\"paper_"]],
                ["index": 0, "id": "a", "function": ["name": "search_", "arguments": "{\"query\":"]]]]],
            ["delta": ["tool_calls": [["index": 0, "function": ["name": "library", "arguments": "\"test\"}"]],
                                       ["index": 1, "function": ["arguments": "id\":\"p\"}"]]]], "finish_reason": "tool_calls"]
        ]
        for chunk in chunks { for event in LLMClient.agentEvents(from: chunk, streaming: true) { try state.append(event) } }
        let calls = try state.completedCalls()
        XCTAssertEqual(calls.map(\.name), ["search_library", "get_blocks"])
        XCTAssertEqual(try calls[0].decodedArguments()["query"] as? String, "test")
        XCTAssertEqual(try calls[1].decodedArguments()["paper_id"] as? String, "p")
        XCTAssertEqual(state.content, "intermediate")
    }
    func testNonStreamingAndSSEFixtures() async throws {
        for streaming in [false, true] {
            let choice: [String: Any] = [streaming ? "delta" : "message": ["content": NSNull(), "tool_calls": [
                ["index": 0, "id": "call", "function": ["name": "search_library", "arguments": "{\"query\":\"test\"}"]]]], "finish_reason": "tool_calls"]
            let json = AnalysisEngine.jsonString(["choices": [choice]])
            AgentFixtureProtocol.fixture = Data((streaming ? "data: " + json + "\n\ndata: [DONE]\n\n" : json).utf8)
            AgentFixtureProtocol.status = 200; AgentFixtureProtocol.requests = 0
            var state = LLMAgentAccumulator()
            for try await event in LLMClient.agentResponse(messages: [], tools: [], llm: config(streaming: streaming), session: session()) { try state.append(event) }
            XCTAssertEqual(try state.completedCalls().first?.name, "search_library")
            XCTAssertEqual(AgentFixtureProtocol.requests, 1)
        }
    }
    func testRejectedToolsAndLengthNeverRetry() async throws {
        AgentFixtureProtocol.fixture = Data(#"{"error":{"message":"tools unsupported"}}"#.utf8)
        AgentFixtureProtocol.status = 400; AgentFixtureProtocol.requests = 0
        do {
            for try await _ in LLMClient.agentResponse(messages: [], tools: [], llm: config(streaming: false), session: session()) {}
            XCTFail("Rejection must fail")
        } catch { XCTAssertEqual(AgentFixtureProtocol.requests, 1) }
        var state = LLMAgentAccumulator()
        try state.append(.finishReason("length"))
        XCTAssertThrowsError(try state.completedCalls())
        try state.append(.toolCallDelta(index: 0, id: "id", name: "name", arguments: "not JSON"))
        try state.append(.finishReason("tool_calls"))
        XCTAssertThrowsError(try state.completedCalls())
    }
}
