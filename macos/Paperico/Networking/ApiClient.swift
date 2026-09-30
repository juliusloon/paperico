import Foundation

// MARK: - Errors (mirrors client.ts error handling: "{status}: {message}")

struct ApiError: LocalizedError, Sendable {
    let statusCode: Int
    let message: String

    var errorDescription: String? { "\(statusCode): \(message)" }
}

enum ApiFailure: LocalizedError, Sendable {
    case network(String)
    case timeout
    case api(ApiError)

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .timeout: return "请求超时，请重试。后台论文处理不会因此中断。"
        case .api(let error): return error.errorDescription
        }
    }

    static func wrap(_ error: Error) -> ApiFailure {
        if let failure = error as? ApiFailure { return failure }
        if let apiError = error as? ApiError { return .api(apiError) }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut { return .timeout }
            return .network(urlError.localizedDescription)
        }
        return .network(error.localizedDescription)
    }
}

// MARK: - Lenient JSON value (settings dicts, SSE payloads)

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(any: Any) {
        switch any {
        case is NSNull: self = .null
        case let n as NSNumber:
            // Distinguish booleans from numbers the way JSONSerialization would not.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? container.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Server configuration

enum ServerConfig {
    static let key = "paperico:server-base"
    static let defaultValue = "http://127.0.0.1:8000"

    static var baseURL: URL {
        var raw = UserDefaults.standard.string(forKey: key) ?? defaultValue
        if raw.isEmpty { raw = defaultValue }
        while raw.hasSuffix("/") { raw.removeLast() }
        return URL(string: raw) ?? URL(string: defaultValue)!
    }
}

// MARK: - SSE

struct SseEvent: Sendable {
    var event: String?
    var data: String
}

/// Parses the `text/event-stream` emitted by sse-starlette:
/// named events (`chunk` / `error` / `done`) with a single JSON data line,
/// comment lines starting with `:` are ignored.
struct SseDecoder {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func feed(line: String) -> SseEvent? {
        if line.isEmpty {
            guard dataLines.isEmpty == false else { eventName = nil; return nil }
            let event = SseEvent(event: eventName, data: dataLines.joined(separator: "\n"))
            eventName = nil
            dataLines = []
            return event
        }
        if line.hasPrefix(":") { return nil } // comment / keep-alive ping
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            dataLines.append(payload)
        }
        return nil
    }
}

// MARK: - Chat stream events (fields the web client actually consumes)

struct ChatStreamEvent: Sendable {
    var content: String?
    var sessionId: String?
    var messageId: String?
    var citedBlockIds: [String]?
    var error: String?
}

// MARK: - ApiClient (mirrors api/client.ts)

final class ApiClient: Sendable {
    let listTimeout: TimeInterval = 10

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    // MARK: low-level helpers

    /// Builds a request against the configured server. `path` may include a query string
    /// (e.g. "api/papers?project_id=1").
    private func request(_ path: String, method: String = "GET", timeout: TimeInterval? = nil) -> URLRequest {
        var url: URL
        if let questionIndex = path.firstIndex(of: "?") {
            var components = URLComponents(url: ServerConfig.baseURL, resolvingAgainstBaseURL: false)!
            components.path = "/" + path[..<questionIndex]
            components.percentEncodedQuery = path[path.index(after: questionIndex)...].description
            url = components.url ?? ServerConfig.baseURL
        } else {
            url = ServerConfig.baseURL.appendingPathComponent(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout ?? 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func parseErrorBody(_ data: Data?, statusCode: Int) -> ApiError {
        var message = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        if let data, let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "message"] {
                if let detail = payload[key] as? String, !detail.trimmingCharacters(in: .whitespaces).isEmpty {
                    message = detail
                    break
                }
            }
        }
        return ApiError(statusCode: statusCode, message: message)
    }

    @discardableResult
    private func fetchJSON<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval? = nil) async throws -> T {
        var request = self.request(path, method: method, timeout: timeout)
        request.httpBody = body
        let (data, response) = try await run(request)
        guard (200..<300).contains(response.statusCode) else { throw parseErrorBody(data, statusCode: response.statusCode) }
        do { return try decoder.decode(T.self, from: data) }
        catch {
            throw ApiError(statusCode: response.statusCode, message: "响应解析失败: \(error.localizedDescription)")
        }
    }

    private func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiFailure.network("无效的服务器响应")
            }
            return (data, http)
        } catch {
            throw ApiFailure.wrap(error)
        }
    }

    private func jsonBody(_ payload: some Encodable) throws -> Data {
        try encoder.encode(payload)
    }

    // MARK: Projects

    func projectsList() async throws -> [ProjectGroup] {
        try await fetchJSON([ProjectGroup].self, "api/projects", timeout: listTimeout)
    }

    func projectsCreate(_ data: ProjectGroup) async throws -> ProjectGroup {
        try await fetchJSON(ProjectGroup.self, "api/projects", method: "POST", body: try jsonBody(data))
    }

    func projectsUpdate(id: String, _ data: ProjectGroup) async throws -> ProjectGroup {
        try await fetchJSON(ProjectGroup.self, "api/projects/\(id)", method: "PUT", body: try jsonBody(data))
    }

    func projectsDelete(id: String) async throws -> OkResponse {
        try await fetchJSON(OkResponse.self, "api/projects/\(id)", method: "DELETE")
    }

    // MARK: Papers

    func papersList(projectId: String? = nil, status: String? = nil, q: String? = nil) async throws -> [PaperListItem] {
        var query: [URLQueryItem] = []
        if let projectId, !projectId.isEmpty { query.append(.init(name: "project_id", value: projectId)) }
        if let status, !status.isEmpty { query.append(.init(name: "status", value: status)) }
        if let q, !q.isEmpty { query.append(.init(name: "q", value: q)) }
        var path = "api/papers"
        if !query.isEmpty {
            var components = URLComponents(url: ServerConfig.baseURL, resolvingAgainstBaseURL: false)!
            components.path = "/api/papers"
            components.queryItems = query
            guard let url = components.url else { throw ApiFailure.network("无效的查询参数") }
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "?" + (components.percentEncodedQuery ?? "")
        }
        return try await fetchJSON([PaperListItem].self, path, timeout: listTimeout)
    }

    func papersUpload(fileData: Data, fileName: String, projectId: String?, sourceUrl: String?) async throws -> PaperListItem {
        let boundary = "paperico-\(UUID().uuidString)"
        var request = self.request("api/papers", method: "POST", timeout: 120)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        // Mirror the web client: only include fields the backend asked for.
        if let projectId, !projectId.isEmpty { appendField("project_id", projectId) }
        if let sourceUrl, !sourceUrl.isEmpty { appendField("source_url", sourceUrl) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await run(request)
        guard (200..<300).contains(response.statusCode) else { throw parseErrorBody(data, statusCode: response.statusCode) }
        do { return try decoder.decode(PaperListItem.self, from: data) }
        catch { throw ApiError(statusCode: response.statusCode, message: "上传响应解析失败") }
    }

    func papersGet(id: String) async throws -> PaperDetail {
        try await fetchJSON(PaperDetail.self, "api/papers/\(id)")
    }

    func papersStatus(id: String) async throws -> PaperStatusOut {
        try await fetchJSON(PaperStatusOut.self, "api/papers/\(id)/status")
    }

    func papersReparse(id: String) async throws -> PaperStatusOut {
        try await fetchJSON(PaperStatusOut.self, "api/papers/\(id)/reparse", method: "POST")
    }

    func papersRetranslate(id: String) async throws -> PaperStatusOut {
        try await fetchJSON(PaperStatusOut.self, "api/papers/\(id)/retranslate", method: "POST")
    }

    func papersMove(paperIds: [String], projectId: String?) async throws -> MoveResponse {
        struct Payload: Encodable { let paperIds: [String]; let projectId: String? }
        return try await fetchJSON(MoveResponse.self, "api/papers/project", method: "PATCH", body: try jsonBody(Payload(paperIds: paperIds, projectId: projectId)))
    }

    func papersRename(id: String, title: String) async throws -> PaperListItem {
        struct Payload: Encodable { let title: String }
        return try await fetchJSON(PaperListItem.self, "api/papers/\(id)/title", method: "PATCH", body: try jsonBody(Payload(title: title)))
    }

    func papersDelete(id: String) async throws -> OkResponse {
        try await fetchJSON(OkResponse.self, "api/papers/\(id)", method: "DELETE")
    }

    /// Original PDF for PDFKit.
    func papersPdfURL(id: String) -> URL {
        ServerConfig.baseURL.appendingPathComponent("api/papers/\(id)/pdf")
    }

    /// Stored figure/table image.
    ///
    /// 后端把 `storage_root` 挂载在 `/api/files`(backend/app/main.py),
    /// Web 端用的也是 `/api/files/<image_path>`。这里原先写成把 `image_path`
    /// 直接相对 baseURL 解析(→ `http://host/mineru_output/...`),结果是 404:
    /// 阅读页每一张图表都取不到,`AsyncImage` 在每次重渲染时无限重试。
    func filesURL(_ imagePath: String) -> URL? {
        guard !imagePath.isEmpty else { return nil }
        let trimmed = imagePath.hasPrefix("/") ? String(imagePath.dropFirst()) : imagePath
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        guard var components = URLComponents(url: ServerConfig.baseURL, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.percentEncodedPath += "/api/files/" + encoded
        return components.url
    }

    // MARK: Chat

    func chatListSessions(paperId: String) async throws -> [ChatSession] {
        try await fetchJSON([ChatSession].self, "api/papers/\(paperId)/chat")
    }

    func chatGetSession(paperId: String, sessionId: String) async throws -> ChatSession {
        try await fetchJSON(ChatSession.self, "api/papers/\(paperId)/chat/\(sessionId)")
    }

    /// POST /chat and stream SSE events (mirrors api.chat.send async generator).
    func chatSend(paperId: String, content: String, sessionId: String?, attachedContext: [AttachedContext]?) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        struct Payload: Encodable {
            let content: String
            let sessionId: String?
            let attachedContext: [AttachedContext]?
        }
        var request = self.request("api/papers/\(paperId)/chat", method: "POST", timeout: 600)
        request.httpBody = try? jsonBody(Payload(content: content, sessionId: sessionId, attachedContext: attachedContext))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw ApiError(statusCode: statusCode, message: "Chat failed: \(statusCode)")
                    }
                    var sse = SseDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if let event = sse.feed(line: line) {
                            guard let data = event.data.data(using: .utf8),
                                  let payload = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { continue }

                            if let errorText = payload["error"]?.stringValue, !errorText.isEmpty {
                                throw ApiError(statusCode: http.statusCode, message: errorText)
                            }
                            var parsed = ChatStreamEvent()
                            if let c = payload["content"]?.stringValue { parsed.content = c }
                            if let s = payload["session_id"]?.stringValue { parsed.sessionId = s }
                            if let m = payload["message_id"]?.stringValue { parsed.messageId = m }
                            if case .array(let ids)? = payload["cited_block_ids"] {
                                parsed.citedBlockIds = ids.compactMap(\.stringValue)
                            }
                            continuation.yield(parsed)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Notes

    func notesList(paperId: String) async throws -> [Note] {
        try await fetchJSON([Note].self, "api/papers/\(paperId)/notes")
    }

    func notesSynthesize(paperId: String, title: String, messageIds: [String]) async throws -> Note {
        struct Payload: Encodable { let title: String; let messageIds: [String] }
        return try await fetchJSON(Note.self, "api/papers/\(paperId)/notes/synthesize", method: "POST", body: try jsonBody(Payload(title: title, messageIds: messageIds)))
    }

    // MARK: Settings

    func settingsGet() async throws -> AppSettings {
        try await fetchJSON(AppSettings.self, "api/settings")
    }

    /// PUT with a merged partial body (AppSettingsUpdate on the backend).
    func settingsUpdate(partialBody: Data) async throws -> AppSettings {
        try await fetchJSON(AppSettings.self, "api/settings", method: "PUT", body: partialBody)
    }

    func settingsTestLLM(baseUrl: String, apiKey: String, model: String, profileId: String) async throws -> TestConnectionResult {
        struct Payload: Encodable { let baseUrl: String; let apiKey: String; let model: String; let profileId: String }
        return try await fetchJSON(TestConnectionResult.self, "api/settings/test-llm", method: "POST", body: try jsonBody(Payload(baseUrl: baseUrl, apiKey: apiKey, model: model, profileId: profileId)))
    }

    func settingsTestMinerU(mode: String, baseUrl: String, localUrl: String, apiKey: String) async throws -> TestConnectionResult {
        struct Payload: Encodable { let mode: String; let baseUrl: String; let localUrl: String; let apiKey: String }
        return try await fetchJSON(TestConnectionResult.self, "api/settings/test-mineru", method: "POST", body: try jsonBody(Payload(mode: mode, baseUrl: baseUrl, localUrl: localUrl, apiKey: apiKey)))
    }

    // MARK: Library

    func libraryMethods(projectId: String? = nil, category: String? = nil, q: String? = nil) async throws -> [MethodIndexItem] {
        var query: [URLQueryItem] = []
        if let projectId, !projectId.isEmpty { query.append(.init(name: "project_id", value: projectId)) }
        if let category, !category.isEmpty { query.append(.init(name: "category", value: category)) }
        if let q, !q.isEmpty { query.append(.init(name: "q", value: q)) }
        var path = "api/library/methods"
        if !query.isEmpty {
            var components = URLComponents(url: ServerConfig.baseURL, resolvingAgainstBaseURL: false)!
            components.path = "/api/library/methods"
            components.queryItems = query
            guard let url = components.url else { throw ApiFailure.network("无效的查询参数") }
            path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "?" + (components.percentEncodedQuery ?? "")
        }
        return try await fetchJSON([MethodIndexItem].self, path)
    }

    // MARK: Health

    func health() async throws -> Bool {
        struct Health: Decodable { let status: String }
        let result = try await fetchJSON(Health.self, "api/health", timeout: 5)
        return result.status == "ok"
    }
}

struct OkResponse: Codable, Sendable {
    var ok: Bool

    init(ok: Bool = true) { self.ok = ok }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        ok = (try? container.decode(Bool.self)) ?? true
    }
}

struct MoveResponse: Codable, Sendable {
    var ok: Bool
    var moved: Int
    var projectId: String?
}
