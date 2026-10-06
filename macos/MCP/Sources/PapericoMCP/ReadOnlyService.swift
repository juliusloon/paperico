import Foundation
import MCP

public struct PapericoMCPPayload: Sendable {
    public let json: Data
    public let image: Data?
    public let mimeType: String?

    public init(json: Data, image: Data? = nil, mimeType: String? = nil) {
        self.json = json
        self.image = image
        self.mimeType = mimeType
    }
}

/// Owns only the SDK/transport. The app supplies queries against its existing actor.
public actor PapericoMCPServer {
    public typealias Query = @Sendable (String, Data) async throws -> PapericoMCPPayload
    private let query: Query
    private var listener: LoopbackHTTPListener?

    public init(query: @escaping Query) { self.query = query }

    public func start(token: String, port: UInt16 = 0) async throws -> URL {
        guard listener == nil, token.utf8.count >= 32,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw MCPError.invalidParams("A server needs a new listener and a strong bearer token.")
        }
        let service = ReadOnlyService(query: query)
        let listener = LoopbackHTTPListener(token: token) { request in
            await service.handle(request)
        }
        self.listener = listener
        do {
            let boundPort = try await listener.start(port: port)
            return URL(string: "http://127.0.0.1:\(boundPort)/mcp")!
        } catch {
            await listener.stop()
            self.listener = nil
            throw error
        }
    }

    public func stop() async {
        let previous = listener
        listener = nil
        await previous?.stop()
    }
}

/// Read-only MCP surface. Internal (not private) so `MCPSchemaSnapshotTests` can
/// assert the contract external clients depend on — see CONTRIBUTING.md.
struct ReadOnlyService: Sendable {
    let query: PapericoMCPServer.Query

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // An independent server/transport per HTTP exchange avoids collisions in
        // request IDs and client capabilities across concurrent stateless clients.
        let server = Server(name: "Paperico", version: "0.3.0", instructions:
            "Read-only access to the running Paperico app. Cite paper_id and block_id. Start from the 'brief' resource for a compressed logic chain and method index, then read 'blocks' only when you need the original text. Library search matches titles and filenames. No API keys or paid actions are exposed.",
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        let transport = StatelessHTTPServerTransport()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: Self.tools) }
        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = Self.tools.first(where: { $0.name == params.name }) else {
                throw MCPError.invalidParams("Unknown read-only tool: \(params.name)")
            }
            do {
                let arguments = params.arguments ?? [:]
                try Self.validate(arguments, schema: tool.inputSchema)
                let payload = try await query(params.name, JSONEncoder().encode(arguments))
                var content: [Tool.Content] = [.text(text: String(decoding: payload.json, as: UTF8.self), annotations: nil, _meta: nil)]
                if let image = payload.image, let mime = payload.mimeType {
                    content.append(.image(data: image.base64EncodedString(), mimeType: mime, annotations: nil, _meta: nil))
                }
                let value = try JSONDecoder().decode(Value.self, from: payload.json)
                // Structured content must be an object; block results are objects too.
                return .init(content: content, structuredContent: Optional.some(value), isError: false)
            } catch {
                return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { params in
            let offset: Int
            if let cursor = params.cursor {
                guard let value = Int(cursor), value >= 0 else { throw MCPError.invalidParams("Invalid resource cursor") }
                offset = value
            } else { offset = 0 }
            let arguments: [String: Value] = ["offset": .int(offset), "limit": .int(50)]
            let payload = try await query("list_papers", JSONEncoder().encode(arguments))
            let page = try JSONDecoder().decode(PaperPage.self, from: payload.json)
            let resources = page.items.flatMap { paper in
                Self.resourceKinds.map { kind in
                    Resource(name: "\(paper.id)/\(kind)", uri: "paperico://paper/\(paper.id)/\(kind)",
                             title: "\(paper.title.isEmpty ? paper.original_file_name : paper.title) — \(kind)", mimeType: "application/json")
                }
            }
            return .init(resources: resources, nextCursor: page.next_offset.map(String.init))
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: Self.resourceKinds.map { kind in
                .init(uriTemplate: "paperico://paper/{paper_id}/\(kind)", name: "paper/\(kind)", mimeType: "application/json")
            })
        }
        await server.withMethodHandler(ReadResource.self) { params in
            guard let uri = URLComponents(string: params.uri), uri.scheme == "paperico", uri.host == "paper",
                  uri.user == nil, uri.password == nil, uri.port == nil, uri.query == nil, uri.fragment == nil else {
                throw MCPError.invalidParams("Invalid paper resource URI")
            }
            let parts = uri.path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].isEmpty, !parts[1].isEmpty, Self.resourceKinds.contains(String(parts[2])) else {
                throw MCPError.invalidParams("Unknown paper resource")
            }
            let kind = String(parts[2])
            let name = kind == "metadata" ? "get_paper" : "resource_\(kind)"
            let payload = try await query(name, JSONEncoder().encode(["paper_id": String(parts[1])]))
            return .init(contents: [.text(String(decoding: payload.json, as: UTF8.self), uri: params.uri, mimeType: "application/json")])
        }
        do {
            try await server.start(transport: transport)
            // Also bounds malformed requests/SDK waiters that do not produce a response.
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await transport.disconnect()
                await server.stop()
            }
            let response = await withTaskCancellationHandler {
                await transport.handleRequest(request)
            } onCancel: {
                Task { await transport.disconnect(); await server.stop() }
            }
            timeout.cancel()
            await server.stop()
            return response
        } catch {
            await server.stop()
            return .error(statusCode: 500, .internalError("MCP server unavailable"))
        }
    }

    private struct PaperPage: Decodable {
        struct Paper: Decodable { let id: String; let title: String; let original_file_name: String }
        let items: [Paper]
        let next_offset: Int?
    }

    static let resourceKinds = ["metadata", "brief", "blocks", "chat", "notes"]
    private static let string: Value = ["type": "string", "minLength": 1, "maxLength": 512]
    private static let paging: [String: Value] = [
        "offset": ["type": "integer", "minimum": 0],
        "limit": ["type": "integer", "minimum": 1, "maximum": 200]
    ]
    private static let paperFilters: [String: Value] = ["project_id": string, "status": string, "query": string]
    private static let methodFilters: [String: Value] = ["project_id": string, "category": string, "query": string]

    static let tools: [Tool] = [
        tool("list_papers", "List library papers, filtered by project/status/title/filename, with pagination.", paperFilters.merging(paging) { $1 }),
        tool("search_library", "Search original title, Chinese title and filename (not full text).", paperFilters.merging(paging) { $1 }, ["query"]),
        tool("get_paper", "Read metadata, TL;DR, contributions, method entities and logical outline without marking the paper as opened.", ["paper_id": string], ["paper_id"]),
        tool("get_blocks", "Read a page of original/translated blocks with block IDs and evidence links.", paging.merging(["paper_id": string]) { $1 }, ["paper_id"]),
        tool("get_block", "Read one evidence block from an active paper.", ["paper_id": string, "block_id": string], ["paper_id", "block_id"]),
        tool("get_figure", "Read a block and its local figure as image content (maximum 4 MiB).", ["paper_id": string, "block_id": string], ["paper_id", "block_id"]),
        tool("list_projects", "List project groups with paper counts.", paging),
        tool("get_method_index", "Read cross-paper method index and cited block IDs.", methodFilters.merging(paging) { $1 }),
        tool("search_methods", "Search method names with optional project/category filters.", methodFilters.merging(paging) { $1 }, ["query"]),
        tool("get_notes", "Read existing notes without generating or changing them.", paging.merging(["paper_id": string]) { $1 }, ["paper_id"])
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Value], _ required: [String] = []) -> Tool {
        Tool(name: name, description: description,
             inputSchema: ["type": "object", "properties": .object(properties), "required": .array(required.map(Value.string)), "additionalProperties": false],
             annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false))
    }

    private static func validate(_ arguments: [String: Value], schema: Value) throws {
        guard case .object(let root) = schema, case .object(let properties) = root["properties"] else { return }
        if case .array(let required) = root["required"] {
            for case .string(let key) in required where arguments[key] == nil {
                throw MCPError.invalidParams("Missing argument: \(key)")
            }
        }
        for (key, value) in arguments {
            guard case .object(let rule) = properties[key] else { throw MCPError.invalidParams("Unknown argument: \(key)") }
            if rule["type"] == .string("string") {
                guard case .string(let text) = value, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= 512 else { throw MCPError.invalidParams("Invalid string: \(key)") }
            } else {
                guard case .int(let number) = value, number >= 0,
                      key != "limit" || (1...200).contains(number) else { throw MCPError.invalidParams("Invalid integer: \(key)") }
            }
        }
    }
}
