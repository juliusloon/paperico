import XCTest
import Foundation
import MCP
import Network
@testable import PapericoCore
@testable import PapericoMCP

final class MCPIntegrationTests: XCTestCase {
    private var root: URL!
    private let token = String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func fixture() async throws -> (PaperLibrary, String, Block) {
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\nmcp fixture".utf8), fileName: "Graph.pdf", projectId: nil)
        let block = Block(id: "block-1", order: 0, kind: "figure", pageIdx: 0, bbox: nil, sectionTitle: "Results",
                          textOriginal: "Original evidence", textZh: "原始证据", oneLiner: "测试证据", keywords: [], roleInNarrative: "",
                          imagePath: "mineru_output/\(paper.id)/images/figure.png", captionOriginal: "Figure 1", captionZh: "图 1",
                          figureType: "", coreTakeaways: [], dataReadingNotes: "", tableHtml: "", latex: "", plainExplanation: "", entityRefs: [])
        try await library.writeBlocks(paperId: paper.id, blocks: [block])
        try await library.writeEntities(paperId: paper.id, entities: [.init(id: "method-1", canonicalKey: "graph", name: "Graph", category: "model", definitionZh: "图模型", blockRefs: [block.id])])
        let image = root.appendingPathComponent(block.imagePath)
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1sAAAAASUVORK5CYII=")!.write(to: image)
        return (library, paper.id, block)
    }

    private func server(_ library: PaperLibrary) -> PapericoMCPServer {
        PapericoMCPServer { name, arguments in
            let value = try await library.automationQuery(name, arguments: arguments)
            return .init(json: value.json, image: value.image, mimeType: value.mimeType)
        }
    }

    private func send(_ endpoint: URL, _ body: [String: Any], authorization: String? = nil, origin: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(authorization ?? "Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func array(_ data: Data) throws -> [[String: Any]] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]) }
    private func call(_ name: String, arguments: [String: Any] = [:], id: Int = 1) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
    }

    func testRealHTTPInitializeToolsResourcesFiguresAndReadOnlyPersistence() async throws {
        let (library, paperId, block) = try await fixture()
        let indexURL = root.appendingPathComponent("library.json")
        let before = try Data(contentsOf: indexURL)
        let server = server(library)
        let endpoint = try await server.start(token: token)
        do {
            let (status, initialization) = try await send(endpoint, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])
            XCTAssertEqual(status, 200)
            let result = try XCTUnwrap(object(initialization)["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
            let (notificationStatus, _) = try await send(endpoint, ["jsonrpc": "2.0", "method": "notifications/initialized"])
            XCTAssertEqual(notificationStatus, 202)
            let (_, listed) = try await send(endpoint, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
            let toolsResult = try XCTUnwrap(object(listed)["result"] as? [String: Any])
            let tools = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 10)
            for tool in tools { XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true) }

            for name in ["list_papers", "search_library", "list_projects", "get_method_index", "search_methods", "get_paper", "get_blocks", "get_block", "get_figure", "get_notes"] {
                var args: [String: Any] = [:]
                if name.hasPrefix("search") { args["query"] = "graph" }
                if ["get_paper", "get_blocks", "get_block", "get_figure", "get_notes"].contains(name) { args["paper_id"] = paperId }
                if ["get_block", "get_figure"].contains(name) { args["block_id"] = block.id }
                let (status, data) = try await send(endpoint, call(name, arguments: args))
                XCTAssertEqual(status, 200, name)
                let value = try XCTUnwrap(object(data)["result"] as? [String: Any])
                XCTAssertEqual(value["isError"] as? Bool, false, name)
                if name == "get_figure" {
                    let content = try XCTUnwrap(value["content"] as? [[String: Any]])
                    XCTAssertEqual(content.last?["type"] as? String, "image")
                    XCTAssertEqual(content.last?["mimeType"] as? String, "image/png")
                }
            }
            let (_, resources) = try await send(endpoint, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
            let resourceResult = try XCTUnwrap(object(resources)["result"] as? [String: Any])
            XCTAssertEqual((resourceResult["resources"] as? [Any])?.count, 5)
            for kind in ["metadata", "brief", "blocks", "chat", "notes"] {
                let (_, data) = try await send(endpoint, ["jsonrpc": "2.0", "id": 4, "method": "resources/read", "params": ["uri": "paperico://paper/\(paperId)/\(kind)"]])
                XCTAssertNotNil(try object(data)["result"], kind)
            }
            XCTAssertEqual(try Data(contentsOf: indexURL), before)
            let paper = await library.paper(id: paperId)
            XCTAssertNil(paper?.lastOpenedAt)
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    func testHTTPAuthorizationOriginAndConcurrentClientIDs() async throws {
        let (library, _, _) = try await fixture()
        let server = server(library)
        let endpoint = try await server.start(token: token)
        do {
            let (unauthorized, _) = try await send(endpoint, call("list_papers"), authorization: "Bearer wrong")
            XCTAssertEqual(unauthorized, 401)
            let (forbidden, _) = try await send(endpoint, call("list_papers"), origin: "https://attacker.example")
            XCTAssertEqual(forbidden, 403)
            let (nullOrigin, _) = try await send(endpoint, call("list_papers"), origin: "null")
            XCTAssertEqual(nullOrigin, 403)
            let counts = try await withThrowingTaskGroup(of: Data.self) { group in
                for _ in 0..<8 {
                    group.addTask { let (_, data) = try await self.send(endpoint, self.call("list_papers", id: 10)); return data }
                }
                var values: [Data] = []
                for try await data in group { values.append(data) }
                return values
            }
            XCTAssertEqual(counts.count, 8)
            for data in counts { XCTAssertEqual(try object(data)["id"] as? Int, 10); XCTAssertNotNil(try object(data)["result"]) }
            let (_, badArgs) = try await send(endpoint, call("list_papers", arguments: ["limit": 1000]))
            XCTAssertEqual((try object(badArgs)["result"] as? [String: Any])?["isError"] as? Bool, true)
            let (_, writes) = try await send(endpoint, call("import_paper"))
            XCTAssertNotNil(try object(writes)["error"])
        } catch { await server.stop(); throw error }
        await server.stop()
        do { _ = try await send(endpoint, call("list_papers")); XCTFail("Stopped listener must refuse connections") } catch { }
    }

    func testTrashAndCrossPaperFigureCannotBeRead() async throws {
        let (library, paperId, block) = try await fixture()
        let args = try JSONSerialization.data(withJSONObject: ["paper_id": paperId, "block_id": block.id])
        var unsafe = block
        unsafe.imagePath = "library.json"
        try await library.writeBlocks(paperId: paperId, blocks: [unsafe])
        do { _ = try await library.automationQuery("get_figure", arguments: args); XCTFail("Must reject files outside this paper's images") } catch { }
        try await library.deletePaper(id: paperId)
        for name in ["get_paper", "get_block", "get_figure", "get_notes", "resource_blocks", "resource_chat", "resource_notes"] {
            do { _ = try await library.automationQuery(name, arguments: args); XCTFail("Trashed paper must be hidden: \(name)") } catch { }
        }
        let traversal = try JSONSerialization.data(withJSONObject: ["paper_id": "../outside"])
        do { _ = try await library.automationQuery("get_paper", arguments: traversal); XCTFail("Traversal must be rejected") } catch { }
    }

    func testHTTPParserRejectsRebindingAmbiguousFramingAndOversizedBodies() throws {
        func request(_ headers: String, _ body: String = "{}") -> Data {
            Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nAuthorization: Bearer \(token)\r\n\(headers)\r\n\r\n\(body)".utf8)
        }
        var parser = HTTPRequestParser(port: 12345, token: token)
        let valid = request("Content-Length: 2")
        XCTAssertNil(try parser.append(valid.prefix(20)))
        XCTAssertNotNil(try parser.append(valid.dropFirst(20)))
        for bad in [request("Content-Length: 2\r\nContent-Length: 2"), request("Content-Length: 2\r\nTransfer-Encoding: chunked"),
                    request("Content-Length: 1048577"), request("Content-Length: 2", "{}{}"),
                    Data("POST /mcp HTTP/1.1\r\nHost: evil.example:12345\r\nAuthorization: Bearer \(token)\r\nContent-Length: 2\r\n\r\n{}".utf8)] {
            var parser = HTTPRequestParser(port: 12345, token: token)
            XCTAssertThrowsError(try parser.append(bad))
        }
    }

    func testOfficialSDKClientInteroperabilityAndTokenRevocation() async throws {
        let (library, paperId, _) = try await fixture()
        let server = server(library)
        let endpoint = try await server.start(token: token)
        let token = token
        let client = Client(name: "Official SDK test", version: "1")
        let transport = HTTPClientTransport(endpoint: endpoint, streaming: false,
                                             requestModifier: { request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        })
        do {
            let initialization = try await client.connect(transport: transport)
            XCTAssertNotNil(initialization.capabilities.tools)
            let (tools, _) = try await client.listTools()
            XCTAssertEqual(tools.count, 10)
            let (content, error) = try await client.callTool(name: "get_paper", arguments: ["paper_id": .string(paperId)])
            XCTAssertEqual(error, false)
            XCTAssertFalse(content.isEmpty)
            let (resources, _) = try await client.listResources()
            XCTAssertEqual(resources.count, 5)
            let blocks = try await client.readResource(uri: "paperico://paper/\(paperId)/blocks")
            XCTAssertEqual(blocks.count, 1)
            await client.disconnect()
            await server.stop()
            let replacement: URL
            do { replacement = try await server.start(token: String(repeating: "b", count: 64), port: UInt16(endpoint.port!)) }
            catch let error as NWError {
                // Closed TCP exchanges can leave this port in TIME_WAIT. Like
                // the app, use a fresh port rather than sharing the old endpoint.
                guard case .posix(.EADDRINUSE) = error else { throw error }
                replacement = try await server.start(token: String(repeating: "b", count: 64))
            }
            let (revoked, _) = try await send(replacement, call("list_papers"))
            XCTAssertEqual(revoked, 401)
            let (accepted, _) = try await send(replacement, call("list_papers"), authorization: "Bearer \(String(repeating: "b", count: 64))")
            XCTAssertEqual(accepted, 200)
        } catch { await client.disconnect(); await server.stop(); throw error }
        await server.stop()
    }

    /// T5: the recommended two-step read. `brief` must be affordable enough to
    /// always fetch, carry every section heading, and stay within the same budget
    /// the in-app chat uses — otherwise external agents read full blocks by default.
    func testBriefIsCompactThenBlocksAreReadOnDemand() async throws {
        let (library, paperId, block) = try await fixture()
        // A second, distinct section heading proves headings survive compression.
        let second = Block(id: "block-2", order: 1, kind: "section_heading", pageIdx: 1, bbox: nil,
                           sectionTitle: "Methods", textOriginal: "Methods", textZh: "方法", oneLiner: "",
                           keywords: [], roleInNarrative: "", imagePath: "", captionOriginal: "",
                           captionZh: "", figureType: "", coreTakeaways: [], dataReadingNotes: "",
                           tableHtml: "", latex: "", plainExplanation: "", entityRefs: [])
        try await library.writeBlocks(paperId: paperId, blocks: [block, second])
        try await library.writeEntities(paperId: paperId, entities: [
            .init(id: "method-1", canonicalKey: "graph", name: "Graph", category: "model",
                  definitionZh: "图模型", blockRefs: [block.id, second.id])
        ])

        let server = server(library)
        let endpoint = try await server.start(token: token)
        do {
            let (_, briefData) = try await send(endpoint,
                ["jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": ["uri": "paperico://paper/\(paperId)/brief"]])
            let brief = try XCTUnwrap(object(briefData)["result"] as? [String: Any])
            let contents = try XCTUnwrap(brief["contents"] as? [[String: Any]])
            let payload = try XCTUnwrap(object(Data((contents[0]["text"] as? String ?? "").utf8)))
            let logicChain = try XCTUnwrap(payload["logic_chain"] as? String)
            let methodIndex = try XCTUnwrap(payload["method_index"] as? String)

            XCTAssertEqual(payload["block_count"] as? Int, 2)
            XCTAssertNotNil(payload["budget"])
            XCTAssertLessThanOrEqual(logicChain.count, ChatContextBuilder.logicChainBudget)
            // Section headings are structural anchors and must never be dropped.
            XCTAssertTrue(logicChain.contains("§"), "Logic chain lost its section anchors: \(logicChain)")
            XCTAssertTrue(logicChain.contains("Methods"), logicChain)
            XCTAssertTrue(methodIndex.contains("Graph(model)"), methodIndex)
            // The whole point: brief is far smaller than the raw blocks.
            XCTAssertLessThan(logicChain.count + methodIndex.count, 500)

            // Step two: only now read the original text.
            let (_, blocksData) = try await send(endpoint,
                ["jsonrpc": "2.0", "id": 2, "method": "resources/read", "params": ["uri": "paperico://paper/\(paperId)/blocks"]])
            let blocksResult = try XCTUnwrap(object(blocksData)["result"] as? [String: Any])
            let blocksContents = try XCTUnwrap(blocksResult["contents"] as? [[String: Any]])
            let blocksPayload = try array(Data((blocksContents[0]["text"] as? String ?? "").utf8))
            XCTAssertEqual(blocksPayload.count, 2)
            XCTAssertEqual(blocksPayload.first?["text_original"] as? String, "Original evidence")
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    /// Opt-in acceptance uses a separate Python process against the production
    /// HTTP server and a snapshot of a real library, rather than synthetic blocks.
    func testExternalProcessReadsRealLibraryBriefThenBlocks() async throws {
        guard let path = ProcessInfo.processInfo.environment["PAPERICO_E2E_LIBRARY_DIR"], !path.isEmpty else {
            throw XCTSkip("Set PAPERICO_E2E_LIBRARY_DIR to verify external-client reads of real papers.")
        }
        let source = URL(fileURLWithPath: path, isDirectory: true)
        for name in ["library.json", "papers", "analyses"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: root.appendingPathComponent(name))
        }
        let library = PaperLibrary(root: root)
        try await library.load()
        let papers = await library.listPapers()
        let paper = try XCTUnwrap(papers.first)
        let server = server(library)
        let secret = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let endpoint = try await server.start(token: secret)
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var environment = ProcessInfo.processInfo.environment
            environment["PAPERICO_ACCEPTANCE_TOKEN"] = secret
            process.environment = environment
            process.arguments = ["-c", """
            import json, os, sys, urllib.request
            endpoint, paper_id = sys.argv[1:]
            def request(method, params, request_id):
                body = json.dumps(dict(jsonrpc='2.0', id=request_id, method=method, params=params)).encode()
                headers = {'Authorization': 'Bearer ' + os.environ['PAPERICO_ACCEPTANCE_TOKEN'],
                           'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream',
                           'MCP-Protocol-Version': '2025-11-25'}
                with urllib.request.urlopen(urllib.request.Request(endpoint, data=body, headers=headers), timeout=10) as response:
                    result = json.load(response)
                assert 'error' not in result, result
                return result['result']
            request('initialize', {'protocolVersion':'2025-11-25', 'capabilities':{},
                                  'clientInfo':{'name':'Python external acceptance', 'version':'1'}}, 1)
            def read(kind, request_id):
                value = request('resources/read', {'uri':f'paperico://paper/{paper_id}/{kind}'}, request_id)
                return json.loads(value['contents'][0]['text'])
            brief = read('brief', 2)
            blocks = read('blocks', 3)
            assert brief['block_count'] == len(blocks) and blocks
            assert '§' in brief['logic_chain'] and 'budget' in brief
            assert any(block.get('text_original') for block in blocks)
            print(f'PASS external Python client: brief → blocks; {len(blocks)} blocks; original IDs retained')
            """, endpoint.absoluteString, paper.id]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, text)
            print(text)
        } catch { await server.stop(); throw error }
        await server.stop()
    }
}
