// Offline integration of the real Zotero importer and PaperPipeline. All HTTP is intercepted.
import Foundation
import Security
import Darwin

private final class ImportedMetadataProtocol: URLProtocol {
    static var archive = Data()
    static var completions = 0
    static var parseSubmissions = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data: Data
            switch request.url?.path {
            case "/file-urls/batch":
                Self.parseSubmissions += 1
                data = Data(#"{"data":{"batch_id":"fixture","file_urls":["https://fixture.invalid/upload"]}}"#.utf8)
            case "/upload": data = Data()
            case "/extract-results/batch/fixture":
                data = Data(#"{"data":{"extract_result":[{"state":"done","full_zip_url":"https://fixture.invalid/results.zip"}]}}"#.utf8)
            case "/results.zip": data = Self.archive
            case "/models": data = Data(#"{"data":[]}"#.utf8)
            case "/chat/completions":
                Self.completions += 1
                let body = try JSONSerialization.jsonObject(with: requestBody()) as? [String: Any]
                let messages = body?["messages"] as? [[String: Any]]
                let prompt = messages?.last?["content"] as? String ?? ""
                let input = try JSONSerialization.jsonObject(with: Data(prompt.components(separatedBy: "逐项完整处理以下 MinerU 结果：\n").last!.utf8)) as! [String: [String: Any]]
                let nodes = input.mapValues { ["source_start": $0["source_start"]!, "zh": "完整中文翻译与科学证据", "note": "中文要点", "role": "方法设计"] }
                let document: [String: Any] = ["nodes": nodes, "methods": [], "paper": ["title": "Wrong model title", "title_zh": "模型译名", "tldr": "模型摘要", "narrative_summary": "全文逻辑", "contributions": ["方法验证"], "domain_tags": [], "difficulty_estimate": "中等"]]
                data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": AnalysisEngine.jsonString(document)]]]])
            default:
                throw PipelineError("Unexpected request; real network is forbidden: " + (request.url?.path ?? "nil"))
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
    override func stopLoading() {}
}

@main struct ZoteroPipelineRegression {
    @MainActor static func main() async {
        do { try await verify() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    @MainActor static func verify() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        ImportedMetadataProtocol.archive = try Data(contentsOf: directory.appendingPathComponent("results.zip"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImportedMetadataProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let library = PaperLibrary(root: directory.appendingPathComponent("library"))
        try await library.load()
        let report = try await ZoteroImport.run(folder: directory.appendingPathComponent("export"), projectId: nil, library: library)
        guard let paper = report.imported.first, report.imported.count == 1 else { throw PipelineError("Fixture import failed") }
        let suite = "paperico-zotero-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CredentialStore(backend: .init(read: { _, _ in .init(data: nil, status: errSecItemNotFound) }, write: { _, _, _ in }))
        let settings = SettingsStore(credentials: credentials, defaults: defaults)
        try await settings.saveLLMProfile(profile: .init(id: "fixture", name: "Fixture", baseUrl: "https://fixture.invalid", apiKey: "fixture", model: "fixture", temperature: 0, maxTokens: 2048, reasoningEffort: "low", streaming: false))
        try await settings.saveMinerU(.init(mode: "cloud", baseUrl: "https://fixture.invalid", localUrl: "", apiKey: "fixture", apiKeyConfigured: true, defaultOptions: MinerUDefaultOptions()))
        let pipeline = PaperPipeline(library: library, settings: settings, session: session)
        pipeline.startProcessing(paperId: paper.id)
        let deadline = Date().addingTimeInterval(10)
        while pipeline.isProcessing(paper.id) {
            guard Date() < deadline else { throw PipelineError("Offline pipeline timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let stored = await library.paper(id: paper.id), stored.status == "ready" else {
            throw PipelineError("Pipeline failed: " + (await library.paper(id: paper.id))!.errorMessage)
        }
        guard stored.title == "Authority title", stored.authors == ["Ada User"], stored.year == 2021,
              stored.venue == "Authority Journal", stored.doi == "10.5555/authority", stored.arxivId == "2101.00001",
              stored.metaSource == MetaSource.manual, stored.titleZh == "模型译名", stored.tldr == "模型摘要",
              ImportedMetadataProtocol.completions == 1, ImportedMetadataProtocol.parseSubmissions == 1 else { throw PipelineError("Imported authority changed or generation repeated") }
        let blocks = try await library.readBlocks(paperId: paper.id)
        guard blocks.contains(where: { !$0.textZh.isEmpty }) else { throw PipelineError("Analysis was not persisted") }
        print("PASS: Zotero import → mock MinerU → production PaperPipeline analysis; six metadata fields retained")
    }
}
