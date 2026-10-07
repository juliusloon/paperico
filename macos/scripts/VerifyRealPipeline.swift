// Opt-in release acceptance. Calls the app's real upload and pipeline code in an
// isolated library; credentials stay in memory. Requires live MinerU and LLM
// endpoints and sends the supplied PDFs to those explicitly configured services.
import Foundation
import Security
import Darwin

@main struct VerifyRealPipeline {
    @MainActor static func main() async {
        do { try await verify() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func verify() async throws {
        let env = ProcessInfo.processInfo.environment
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else { throw PipelineError("Set \(name) to run real acceptance") }
            return value
        }
        let pdfDirectory = URL(fileURLWithPath: try required("PAPERICO_E2E_PDF_DIR"))
        let localURL = try required("PAPERICO_MINERU_LOCAL_URL")
        let modelURL = try required("PAPERICO_E2E_LLM_BASE_URL")
        let model = try required("PAPERICO_E2E_LLM_MODEL")
        let outputBase = env["PAPERICO_E2E_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = outputBase.appendingPathComponent("paperico-acceptance-\(UUID().uuidString)")
        let library = PaperLibrary(root: root)
        try await library.load()
        let credentials = CredentialStore(backend: .init(
            read: { _, _ in .init(data: nil, status: errSecItemNotFound) },
            write: { _, _, _ in }))
        let settings = SettingsStore(credentials: credentials)
        await settings.fetch()
        try await settings.saveLLMProfile(profile: .init(id: "release-check", name: "Release acceptance",
            baseUrl: modelURL, apiKey: env["PAPERICO_E2E_LLM_API_KEY"] ?? "local",
            model: model, temperature: 0.3, maxTokens: 65536,
            reasoningEffort: "medium", streaming: true))
        try await settings.saveMinerU(.init(mode: "local", baseUrl: "https://mineru.net/api/v4",
            localUrl: localURL, apiKey: "", apiKeyConfigured: false,
            defaultOptions: MinerUDefaultOptions()))
        let pipeline = PaperPipeline(library: library, settings: settings)
        let store = PapersStore(library: library, pipeline: pipeline)
        let inputs = Array(try FileManager.default.contentsOfDirectory(at: pdfDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }.sorted { $0.path < $1.path }.prefix(3))
        guard inputs.count == 3 else { throw PipelineError("Provide three distinct real PDFs for queue acceptance") }
        var papers: [PaperListItem] = []
        for input in inputs {
            papers.append(try await store.upload(fileData: Data(contentsOf: input),
                fileName: input.lastPathComponent, projectId: nil))
        }
        print("ACCEPTANCE_ROOT \(root.path)")
        var peakParsing = 0, peakWaiting = 0, last = ""
        let deadline = Date().addingTimeInterval(1200)
        while papers.contains(where: { pipeline.isProcessing($0.id) }) {
            let current = await library.listPapers()
            let parsing = current.filter { $0.status == "parsing" && pipeline.progress[$0.id] == "本地 MinerU 正在解析 PDF" }.count
            let waiting = pipeline.progress.values.filter { $0 == "正在等待解析任务空位" }.count
            peakParsing = max(peakParsing, parsing); peakWaiting = max(peakWaiting, waiting)
            let state = current.map { "\($0.originalFileName):\($0.status):\(pipeline.nodeProgress[$0.id]?.completed ?? 0)/\(pipeline.nodeProgress[$0.id]?.total ?? 0)" }.joined(separator: " | ")
            if state != last { print("PROGRESS parse=\(parsing) queue=\(waiting) \(state)"); last = state }
            guard peakParsing <= 1 else { throw PipelineError("Local parser ran concurrently") }
            guard Date() < deadline else { throw PipelineError("Production pipeline timed out") }
            try await Task.sleep(for: .milliseconds(500))
        }
        let completed = await library.listPapers()
        for paper in completed {
            print("RESULT \(paper.originalFileName) status=\(paper.status) authors=\(paper.authors.count) year=\(paper.year ?? 0) venue=\(paper.venue) doi=\(paper.doi ?? "") error=\(paper.errorMessage)")
            guard paper.status == "ready" else { throw PipelineError("Real paper failed: \(paper.errorMessage)") }
            let blocks = try await library.readBlocks(paperId: paper.id)
            guard !blocks.isEmpty, blocks.contains(where: { !$0.textZh.isEmpty && !$0.roleInNarrative.isEmpty }) else { throw PipelineError("Missing usable translation") }
            let sidecar = await library.analysesDir(paper.id).appendingPathComponent("single_pass.json")
            guard FileManager.default.fileExists(atPath: sidecar.path) else { throw PipelineError("Missing analysis sidecar") }
        }
        guard completed.count == 3, peakParsing == 1, peakWaiting == 2 else { throw PipelineError("Serial queue acceptance failed") }
        guard completed.contains(where: { $0.doi != nil && !$0.authors.isEmpty && $0.year != nil && !$0.venue.isEmpty }) else { throw PipelineError("No persisted DOI metadata") }
        let summary: [String: Any] = ["ready": completed.count, "local_parse_peak": peakParsing,
                                      "queued_peak": peakWaiting, "library_root": root.path]
        try LibraryFiles.writeJSONAny(summary, to: root.appendingPathComponent("acceptance.json"))
        print("PASS production PapersStore.upload → PaperPipeline: 3 ready; local peak=1; queued peak=2; DOI metadata persisted")
    }
}
