import Foundation

/// OpenAI-compatible Chat Completions 客户端(移植 backend/app/services/llm.py,
/// 含 temperature 拒绝重试与流式 SSE 解析)。消息体直接用 JSON 字典,
/// 以兼容多模态分片与响应格式等自由字段。
enum LLMClient {

    /// 接受服务商 Base URL 或直接粘贴的 completions 端点。
    static func normalizeBaseURL(_ base: String) -> String {
        var normalized = base.trimmingCharacters(in: .whitespaces)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        let suffix = "/chat/completions"
        if normalized.hasSuffix(suffix) {
            normalized = String(normalized.dropLast(suffix.count))
            while normalized.hasSuffix("/") { normalized.removeLast() }
        }
        return normalized
    }

    // MARK: - 单次补全

    static func chat(
        messages: [[String: Any]],
        baseURL: String, apiKey: String, model: String,
        temperature: Double? = 0.3,
        maxTokens: Int = 4096,
        responseFormatJSON: Bool = false,
        reasoningEffort: String? = nil,
        timeout: TimeInterval = 120,
        streaming: Bool = false,
        session: URLSession = .shared,
        compatibilityRetries: Bool = true
    ) async throws -> String {
        if streaming {
            var content = ""
            for try await chunk in stream(
                messages: messages, baseURL: baseURL, apiKey: apiKey, model: model,
                temperature: temperature, maxTokens: maxTokens, reasoningEffort: reasoningEffort,
                responseFormatJSON: responseFormatJSON, session: session, compatibilityRetries: compatibilityRetries
            ) { content += chunk }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMServiceError("模型服务未返回正文，请检查输出上限和思考强度")
            }
            return content
        }
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
        ]
        if let temperature { payload["temperature"] = temperature }
        if responseFormatJSON { payload["response_format"] = ["type": "json_object"] }
        payload.merge(reasoningFields(reasoningEffort, model: model, baseURL: baseURL)) { _, new in new }

        let data = try await postCompletions(
            payload: payload, baseURL: baseURL, apiKey: apiKey, timeout: timeout, session: session, compatibilityRetries: compatibilityRetries
        )
        return try content(from: data)
    }

    /// 流式补全:yield content 增量(对齐 llm.py chat_stream)。
    static func stream(
        messages: [[String: Any]],
        baseURL: String, apiKey: String, model: String,
        temperature: Double? = 0.3,
        maxTokens: Int = 4096,
        reasoningEffort: String? = nil,
        responseFormatJSON: Bool = false,
        session: URLSession = .shared,
        compatibilityRetries: Bool = true,
        timeout: TimeInterval = 120
    ) -> AsyncThrowingStream<String, Error> {
        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        payload.merge(reasoningFields(reasoningEffort, model: model, baseURL: baseURL)) { _, new in new }
        if let temperature { payload["temperature"] = temperature }
        if responseFormatJSON { payload["response_format"] = ["type": "json_object"] }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for attempt in 0..<(compatibilityRetries ? 3 : 1) {
                        var request = try makeRequest(baseURL: baseURL, apiKey: apiKey, timeout: timeout)
                        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw LLMServiceError("模型服务响应无效")
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            let body = try? await drainBody(bytes)
                            if compatibilityRetries, attempt < 2, let body,
                               let adjusted = compatiblePayload(payload, statusCode: http.statusCode, body: body) {
                                payload = adjusted
                                continue
                            }
                            throw errorResponse(statusCode: http.statusCode, body: body)
                        }
                        // SSE:每行 "data: {...}",取 choices[0].delta.content 增量。
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data:") else { continue }
                            let dataString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if dataString.trimmingCharacters(in: .whitespaces) == "[DONE]" { break }
                            guard let data = dataString.data(using: .utf8),
                                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                            if chunk["error"] != nil { throw errorResponse(statusCode: http.statusCode, body: data) }
                            guard let choices = chunk["choices"] as? [[String: Any]], let choice = choices.first else { continue }
                            if let delta = choice["delta"] as? [String: Any],
                               let content = delta["content"] as? String, !content.isEmpty {
                                continuation.yield(content)
                            }
                            if choice["finish_reason"] as? String == "length" {
                                throw LLMServiceError("模型输出达到 token 上限，响应被截断；已保留返回内容，请提高输出上限或使用更大输出容量的模型。")
                            }
                        }
                        continuation.finish()
                        return
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Non-streaming providers retain the same consumer interface and cancellation ownership.
    static func response(
        messages: [[String: Any]], baseURL: String, apiKey: String, model: String,
        temperature: Double, maxTokens: Int, reasoningEffort: String?, streaming: Bool
    ) -> AsyncThrowingStream<String, Error> {
        if streaming {
            return stream(messages: messages, baseURL: baseURL, apiKey: apiKey, model: model,
                          temperature: temperature, maxTokens: maxTokens, reasoningEffort: reasoningEffort)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let content = try await chat(messages: messages, baseURL: baseURL, apiKey: apiKey, model: model,
                                                 temperature: temperature, maxTokens: maxTokens, reasoningEffort: reasoningEffort)
                    continuation.yield(content)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 底层

    static func reasoningFields(_ effort: String?, model: String, baseURL: String) -> [String: Any] {
        if model.lowercased().contains("qwen3.5"), effort == "none" || effort == "off" {
            // Qwen's serving template needs this switch; reasoning_effort alone
            // does not select its non-thinking template. DashScope uses a flat flag.
            let host = URL(string: baseURL)?.host?.lowercased() ?? ""
            if host.contains("dashscope.aliyuncs.com") { return ["enable_thinking": false] }
            return ["chat_template_kwargs": ["enable_thinking": false]]
        }
        guard let effort, effort != "off" else { return [:] }
        return ["reasoning_effort": effort]
    }

    static func makeRequest(baseURL: String, apiKey: String, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: normalizeBaseURL(baseURL) + "/chat/completions"),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw LLMServiceError("Base URL 无法解析：\(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func postCompletions(
        payload: [String: Any], baseURL: String, apiKey: String, timeout: TimeInterval, session: URLSession = .shared, compatibilityRetries: Bool = true
    ) async throws -> Data {
        var request = try makeRequest(baseURL: baseURL, apiKey: apiKey, timeout: timeout)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var currentPayload = payload
        for attempt in 0..<(compatibilityRetries ? 3 : 1) {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMServiceError("模型服务响应无效")
            }
            guard (200..<300).contains(http.statusCode) else {
                if compatibilityRetries, attempt < 2,
                   let adjusted = compatiblePayload(currentPayload, statusCode: http.statusCode, body: data) {
                    currentPayload = adjusted
                    request.httpBody = try JSONSerialization.data(withJSONObject: adjusted)
                    continue
                }
                throw errorResponse(statusCode: http.statusCode, body: data)
            }
            return data
        }
        throw LLMServiceError("模型服务请求未完成")
    }

    private static func content(from data: Data) throws -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMServiceError("模型服务响应中缺少 choices[0].message.content")
        }
        if choices.first?["finish_reason"] as? String == "length" {
            throw LLMServiceError("模型输出达到 token 上限，响应被截断，请提高输出上限。")
        }
        let content = message["content"]
        if let text = content as? String { return text }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        throw LLMServiceError("模型服务响应中缺少 choices[0].message.content")
    }

    static func drainBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    static func compatiblePayload(_ payload: [String: Any], statusCode: Int, body: Data) -> [String: Any]? {
        guard statusCode == 400 else { return nil }
        let message = errorMessage(fromBody: body).lowercased()
        var adjusted = payload
        if payload["max_tokens"] != nil, message.contains("max_completion_tokens") {
            adjusted["max_completion_tokens"] = adjusted.removeValue(forKey: "max_tokens")
            return adjusted
        }
        if payload["temperature"] != nil, message.contains("temperature") {
            adjusted.removeValue(forKey: "temperature")
            return adjusted
        }
        return nil
    }

    static func errorResponse(statusCode: Int, body: Data?) -> LLMServiceError {
        var message = body.map { errorMessage(fromBody: $0) } ?? ""
        message = message.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let detail = message.isEmpty ? "" : ": \(String(message.prefix(300)))"
        return LLMServiceError("模型服务返回 HTTP \(statusCode)\(detail)")
    }

    /// 从 error 响应体提取 message/detail/code(对齐 llm.py _error_from_response)。
    static func errorMessage(fromBody data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return String(text.prefix(300))
        }
        let error = payload["error"] ?? payload
        if let dict = error as? [String: Any] {
            for key in ["message", "detail", "code"] {
                if let value = dict[key] as? String, !value.isEmpty { return value }
                if let value = dict[key], !(value is NSNull) { return String(describing: value) }
            }
        } else if let text = error as? String {
            return text
        }
        return ""
    }
}

// MARK: - 能力探测(移植 settings_api.py 的 test-llm)

enum LLMProbe {

    struct Result: Sendable {
        var success: Bool
        var message: String
        var supportsReasoning: Bool?
        var reasoningLevels: [String]?
        var defaultMaxOutputTokens: Int?
    }

    static let reasoningLevels = ["off", "low", "medium", "high"]

    /// 与后端 /api/settings/test-llm 等价:先跑一条最小补全验证连通性,
    /// 再探测 reasoning_effort 支持与 /models 元数据里的输出上限。
    static func testLLM(baseURL: String, apiKey: String, model: String, savedKey: String) async -> Result {
        let base = LLMClient.normalizeBaseURL(baseURL)
        guard !base.isEmpty else { return Result(success: false, message: "请先填写 Base URL") }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Result(success: false, message: "请先填写模型名称")
        }
        let key = apiKey.isEmpty ? savedKey : apiKey
        guard !key.isEmpty else {
            return Result(success: false, message: "请先填写 API Key，或先保存过可用密钥")
        }

        let capability: (success: Bool, supportsReasoning: Bool, error: String)
        do {
            capability = try await probeChatCapability(base: base, apiKey: key, model: model)
        } catch {
            return Result(success: false, message: "连接失败： \(friendly(error))")
        }
        guard capability.success else {
            return Result(success: false, message: "连接失败： \(capability.error)")
        }

        let outputLimit = await probeModelOutputLimit(base: base, apiKey: key, model: model)
        var message = capability.supportsReasoning
            ? "连接成功，该模型支持思考强度调节"
            : "连接成功，该模型不支持思考强度（将保持关闭）"
        if let outputLimit {
            message += "，默认单次最大输出 \(outputLimit)"
        }
        return Result(
            success: true,
            message: message + "。",
            supportsReasoning: capability.supportsReasoning,
            reasoningLevels: capability.supportsReasoning ? reasoningLevels : ["off"],
            defaultMaxOutputTokens: outputLimit
        )
    }

    static func friendly(_ error: Error) -> String {
        if let llm = error as? LLMServiceError { return llm.message }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut { return "请求超时" }
            return "无法访问模型服务(\(urlError.localizedDescription))"
        }
        return String(describing: error).prefix(200).description
    }

    /// 小补全探测:不带/带 reasoning_effort 各请求一次,验证连通性与思考强度支持。
    private static func probeChatCapability(base: String, apiKey: String, model: String) async throws -> (Bool, Bool, String) {
        let url = try ServiceURL.endpoint(base: base, path: "/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }

        let messages: [[String: Any]] = [["role": "user", "content": "Reply with the single word: OK"]]
        // 新版 OpenAI 模型只接受 max_completion_tokens;先按旧字段探测,被拒后降级重试。
        var payload: [String: Any] = ["model": model, "messages": messages, "max_tokens": 128]

        func perform(_ requestPayload: [String: Any]) async throws -> (Data, Int) {
            var probeRequest = request
            probeRequest.httpBody = try JSONSerialization.data(withJSONObject: requestPayload)
            let (responseData, response) = try await URLSession.shared.data(for: probeRequest)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (responseData, statusCode)
        }

        var (data, statusCode) = try await perform(payload)
        if !(200..<300).contains(statusCode) {
            let error = LLMClient.errorMessage(fromBody: data)
            if statusCode == 400 && error.lowercased().contains("max_completion_tokens") {
                payload = ["model": model, "messages": messages, "max_completion_tokens": 128]
                (data, statusCode) = try await perform(payload)
                if !(200..<300).contains(statusCode) {
                    return (false, false, LLMClient.errorMessage(fromBody: data))
                }
            } else {
                return (false, false, error)
            }
        }

        var reasoningPayload = payload
        reasoningPayload["reasoning_effort"] = "low"
        let (_, reasoningStatus) = try await perform(reasoningPayload)
        return (true, (200..<300).contains(reasoningStatus), "")
    }

    /// 显式 output 容量才是输出上限；context 等字段不参与推断。
    static func probeModelOutputLimit(base: String, apiKey: String, model: String, session: URLSession = .shared) async -> Int? {
        await modelCapacity(base: base, apiKey: apiKey, model: model, session: session).limit
    }

    static func modelCapacity(base: String, apiKey: String, model: String, session: URLSession = .shared) async -> (limit: Int?, metadata: [String: Any]) {
        guard let url = URL(string: base + "/models") else { return (nil, ["state": "invalid_url"]) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else {
            return (nil, ["state": "unavailable"])
        }
        guard (200..<300).contains(http.statusCode),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = payload["data"] as? [[String: Any]] else {
            return (nil, ["http_status": http.statusCode, "state": "no_model_data"])
        }
        guard let entry = entries.first(where: { $0["id"] as? String == model }) ?? (entries.count == 1 ? entries.first : nil) else {
            return (nil, ["state": "model_not_found", "model_ids": entries.compactMap { $0["id"] as? String }])
        }
        // 只记录公开能力字段，诊断文件不包含请求头或凭据。
        let allowed = Set(["id", "limit", "limits", "top_provider", "max_completion_tokens", "max_output_tokens", "max_tokens"])
        let metadata = entry.filter { allowed.contains($0.key) }
        let nested = entry["top_provider"] as? [String: Any] ?? [:]
        let limits = entry["limit"] as? [String: Any] ?? entry["limits"] as? [String: Any] ?? [:]
        for source in [nested, limits, entry] {
            for key in ["max_completion_tokens", "max_output_tokens", "max_tokens", "output"] {
                if let value = source[key] as? Int, 0 < value && value <= 1_000_000 { return (value, metadata) }
            }
        }
        return (nil, metadata)
    }
}
