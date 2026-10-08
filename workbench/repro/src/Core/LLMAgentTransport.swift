import Foundation

struct LLMToolCall: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
    var messageValue: [String: Any] { ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]] }
    func decodedArguments() throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMServiceError("工具调用参数必须是 JSON 对象。")
        }
        return value
    }
}

enum LLMAgentEvent: Sendable {
    case content(String)
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String?)
    case finishReason(String)
}

struct LLMAgentAccumulator {
    var content = ""
    private var calls: [Int: LLMToolCall] = [:]
    var finishReason: String?
    mutating func append(_ event: LLMAgentEvent) throws {
        switch event {
        case .content(let text): content += text
        case .finishReason(let reason): finishReason = reason
        case .toolCallDelta(let index, let id, let name, let arguments):
            guard (0..<128).contains(index) else { throw LLMServiceError("工具调用索引越界。") }
            var call = calls[index] ?? LLMToolCall(id: "", name: "", arguments: "")
            call.id += id ?? ""; call.name += name ?? ""; call.arguments += arguments ?? ""
            guard call.arguments.utf8.count <= 32_768, call.id.count <= 256, call.name.count <= 128 else {
                throw LLMServiceError("工具调用参数超出预算。")
            }
            calls[index] = call
        }
    }
    func completedCalls() throws -> [LLMToolCall] {
        guard finishReason != "length" else { throw LLMServiceError("模型输出达到 token 上限，工具调用未完成。") }
        guard calls.isEmpty || finishReason != nil else { throw LLMServiceError("工具调用流未完整结束。") }
        let result = calls.keys.sorted().compactMap { calls[$0] }
        var ids = Set<String>()
        for call in result {
            guard !call.id.isEmpty, !call.name.isEmpty, ids.insert(call.id).inserted else { throw LLMServiceError("模型返回了无效工具调用。") }
            _ = try call.decodedArguments()
        }
        return result
    }
}

extension LLMClient {
    static func agentEvents(from choice: [String: Any], streaming: Bool) -> [LLMAgentEvent] {
        let message = choice[streaming ? "delta" : "message"] as? [String: Any] ?? [:]
        var events: [LLMAgentEvent] = []
        if let text = message["content"] as? String, !text.isEmpty { events.append(.content(text)) }
        else if let parts = message["content"] as? [[String: Any]] {
            events.append(.content(parts.compactMap { $0["text"] as? String }.joined()))
        }
        for (offset, value) in (message["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            let function = value["function"] as? [String: Any] ?? [:]
            events.append(.toolCallDelta(index: value["index"] as? Int ?? offset, id: value["id"] as? String,
                                         name: function["name"] as? String, arguments: function["arguments"] as? String))
        }
        if let reason = choice["finish_reason"] as? String { events.append(.finishReason(reason)) }
        return events
    }

    /// Agent rounds never silently resend a rejected request or restart the chain.
    static func agentResponse(messages: [[String: Any]], tools: [[String: Any]], llm: AnalysisEngine.LLMConfig,
                              toolChoice: Any? = nil, session: URLSession = .shared, timeout: TimeInterval = 120) -> AsyncThrowingStream<LLMAgentEvent, Error> {
        var payload: [String: Any] = ["model": llm.model, "messages": messages, "max_tokens": llm.maxTokens, "stream": llm.streaming]
        payload["temperature"] = llm.temperature
        payload.merge(reasoningFields(llm.reasoningEffort, model: llm.model, baseURL: llm.baseURL)) { _, new in new }
        if !tools.isEmpty { payload["tools"] = tools }
        if let toolChoice { payload["tool_choice"] = toolChoice }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if llm.streaming {
                        var request = try makeRequest(baseURL: llm.baseURL, apiKey: llm.apiKey, timeout: timeout)
                        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                        dlog("AGENT-REQ start tools=\(tools.count) msgs=\(messages.count) stream=\(llm.streaming)")
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else { throw LLMServiceError("模型服务响应无效。") }
                        dlog("AGENT-REQ headers status=\(http.statusCode) ct=\(http.value(forHTTPHeaderField: "Content-Type") ?? "-") te=\(http.value(forHTTPHeaderField: "Transfer-Encoding") ?? "-") conn=\(http.value(forHTTPHeaderField: "Connection") ?? "-")")
                        guard (200..<300).contains(http.statusCode) else { throw errorResponse(statusCode: http.statusCode, body: try? await drainBody(bytes)) }
                        var rawCapture = Data(); var lineCount = 0
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            lineCount += 1
                            if rawCapture.count < 4096 { rawCapture.append(contentsOf: line.utf8); rawCapture.append(0x0a) }
                            guard line.hasPrefix("data:") else { continue }
                            let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if text == "[DONE]" { dlog("AGENT-REQ [DONE] lines=\(lineCount) rawBytes=\(rawCapture.count)"); break }
                            guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            if json["error"] != nil { dlog("AGENT-REQ sse-error: \(text.prefix(400))"); throw errorResponse(statusCode: http.statusCode, body: data) }
                            guard let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                            for event in agentEvents(from: choice, streaming: true) { continuation.yield(event) }
                            if choice["finish_reason"] as? String == "length" { throw LLMServiceError("模型输出达到 token 上限，已保留返回内容。") }
                        }
                        if rawCapture.count < 2000 { dlog("AGENT-REQ stream-end lines=\(lineCount) raw=\(String(decoding: rawCapture, as: UTF8.self).prefix(1900))") }
                        else { dlog("AGENT-REQ stream-end lines=\(lineCount) rawBytes=\(rawCapture.count)") }
                    } else {
                        let data = try await postCompletions(payload: payload, baseURL: llm.baseURL, apiKey: llm.apiKey, timeout: timeout, session: session, compatibilityRetries: false)
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choice = (json["choices"] as? [[String: Any]])?.first else { throw LLMServiceError("模型服务响应中缺少 choices。") }
                        for event in agentEvents(from: choice, streaming: false) { continuation.yield(event) }
                        if choice["finish_reason"] as? String == "length" { throw LLMServiceError("模型输出达到 token 上限。") }
                    }
                    try Task.checkCancellation()
                    dlog("AGENT-REQ finish-ok")
                    continuation.finish()
                } catch { dlog("AGENT-REQ error: \(String(describing: error))"); continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
