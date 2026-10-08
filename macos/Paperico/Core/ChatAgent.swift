import Foundation

/// The model can request evidence, but the local loop owns every execution budget.
@MainActor
final class ChatAgent {
    typealias Response = ([[String: Any]], [[String: Any]], AnalysisEngine.LLMConfig) -> AsyncThrowingStream<LLMAgentEvent, Error>
    static let maxToolRounds = 3
    static let maxToolCalls = 8
    static let contextBudget = 24_000
    private(set) var registry: ChatSourceRegistry
    private(set) var toolRounds = 0
    private(set) var toolCalls = 0
    private(set) var toolNames: [String] = []
    private(set) var paperIds: Set<String> = []
    private(set) var usedCharacters = 0
    private(set) var rankingMilliseconds: [Double] = []
    private(set) var toolMilliseconds: [Double] = []
    let executor: ChatLibraryToolExecutor
    let llm: AnalysisEngine.LLMConfig

    init(registry: ChatSourceRegistry, executor: ChatLibraryToolExecutor, llm: AnalysisEngine.LLMConfig) {
        self.registry = registry; self.executor = executor; self.llm = llm
    }

    func response(messages initial: [[String: Any]], response: Response? = nil,
                  activity: @escaping (String) -> Void) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var messages = initial
                do {
                    for round in 0...Self.maxToolRounds {
                        try Task.checkCancellation()
                        let finalOnly = round == Self.maxToolRounds || self.toolCalls >= Self.maxToolCalls || self.usedCharacters >= Self.contextBudget
                        if finalOnly {
                            messages.append(["role": "system", "content": "工具预算已用尽，不得再调用工具，请仅根据已有证据完成回答。"])
                        }
                        activity("正在组织回答")
                        var accumulator = LLMAgentAccumulator()
                        let tools = finalOnly ? [] : ChatLibraryToolExecutor.schemas
                        let stream = response?(messages, tools, self.llm) ?? LLMClient.agentResponse(messages: messages, tools: tools, llm: self.llm)
                        for try await event in stream {
                            try Task.checkCancellation()
                            try accumulator.append(event)
                            // Only the forced final round is known to be final before its finish event.
                            if finalOnly, case .content(let content) = event { continuation.yield(content) }
                        }
                        try Task.checkCancellation()
                        let calls = try accumulator.completedCalls()
                        if calls.isEmpty {
                            guard !accumulator.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMServiceError("模型未返回回答。") }
                            if !finalOnly { continuation.yield(accumulator.content) }
                            continuation.finish(); return
                        }
                        guard !finalOnly else { throw LLMServiceError("模型在工具预算用尽后仍请求工具，请重新提问。") }
                        self.toolRounds += 1
                        messages.append(["role": "assistant", "content": accumulator.content, "tool_calls": calls.map(\.messageValue)])
                        for call in calls {
                            try Task.checkCancellation()
                            let result: String
                            if self.toolCalls < Self.maxToolCalls && self.usedCharacters < Self.contextBudget {
                                self.toolCalls += 1
                                self.toolNames.append(call.name)
                                activity(call.name == "get_blocks" ? "正在读取原文" : (call.name == "search_library" || call.name == "search_methods" ? "正在检索论文库" : "正在阅读论文摘要"))
                                var updated = self.registry
                                let toolStart = Date()
                                let output = try await self.executor.execute(call, registry: &updated, budget: Self.contextBudget - self.usedCharacters)
                                try Task.checkCancellation()
                                self.toolMilliseconds.append(Date().timeIntervalSince(toolStart) * 1000)
                                if let ms = output.rankingMilliseconds { self.rankingMilliseconds.append(ms) }
                                self.registry = updated
                                self.paperIds.formUnion(output.paperIds)
                                result = output.content
                            } else {
                                result = String("{\"error\":\"tool budget exhausted\"}".prefix(max(0, Self.contextBudget - self.usedCharacters)))
                            }
                            self.usedCharacters += result.count
                            messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
                            activity("正在组织回答")
                        }
                    }
                    throw LLMServiceError("工具轮次超出上限。")
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func isToolsRejection(_ error: Error) -> Bool {
        guard let error = error as? LLMServiceError else { return false }
        let message = error.message.lowercased()
        return (message.contains("http 400") || message.contains("http 422")) &&
            (message.contains("tool") || message.contains("function")) &&
            (message.contains("unsupported") || message.contains("not support") || message.contains("not allowed") || message.contains("unknown parameter"))
    }
}
