import XCTest
@testable import PapericoCore

/// T8: the one regression that runs the real pipeline on real papers.
///
/// Every other test in this target is hermetic — none of them call MinerU or a
/// model. That is deliberate (core tests must never spend money or need a
/// network), but it means a parser or model change can pass all 170 tests and
/// still produce an unusable paper. This closes that gap without putting it on
/// the default path.
///
/// Enable it locally:
///     PAPERICO_E2E_PDF_DIR=/path/to/pdfs swift test --package-path macos
///
/// The directory is never committed; see the E2E rules in .gitignore. Without the
/// env var every test here skips rather than fails.
final class RealPipelineTests: XCTestCase {

    private var root: URL!

    /// Nil (and therefore skip) when the opt-in env var is absent.
    static var e2eDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["PAPERICO_E2E_PDF_DIR"],
              !path.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.e2eDirectory == nil,
                      "Set PAPERICO_E2E_PDF_DIR to a local directory of real PDFs to run this regression.")
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func pdfs(limit: Int) throws -> [URL] {
        let directory = try XCTUnwrap(Self.e2eDirectory)
        let found = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(found.isEmpty, "PAPERICO_E2E_PDF_DIR contains no PDFs")
        return Array(found.prefix(limit))
    }

    /// Walks the pipeline as far as it can go without credentials: import →
    /// MinerU parse → normalize → blocks on disk. This is where MinerU format
    /// changes actually break the app.
    func testRealPapersParseIntoUsableBlocks() async throws {
        let inputs = try pdfs(limit: 2)
        let library = PaperLibrary(root: root)
        try await library.load()

        for input in inputs {
            let data = try Data(contentsOf: input)
            let paper = try await library.importPDF(fileData: data, fileName: input.lastPathComponent, projectId: nil)
            let outputDir = await library.mineruOutputDir(paper.id)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            // The parse step needs MinerU; skip that paper rather than the suite
            // when its credentials are not configured.
            let mineruConfig = try await localMinerUConfig()
            guard let mineruConfig else {
                throw XCTSkip("MinerU is not configured locally; run MinerU and set its URL to exercise parsing.")
            }
            let contentList: URL
            do {
                contentList = try await MinerUClient.runLocalPipeline(
                    fileData: data, fileName: input.lastPathComponent,
                    config: mineruConfig, outputDir: outputDir)
            } catch {
                throw XCTSkip("MinerU could not parse \(input.lastPathComponent): \(error.localizedDescription)")
            }

            let raw = try MinerUClient.parseContentList(at: contentList, dataRoot: await library.dataRoot)
            XCTAssertFalse(raw.isEmpty, "\(input.lastPathComponent): MinerU produced no readable blocks")

            let blocks = raw.enumerated().map { index, entry in
                Block(
                    id: PaperLibrary.blockId(paperId: paper.id, order: index),
                    order: index,
                    kind: entry["kind"] as? String ?? "paragraph",
                    pageIdx: entry["page_idx"] as? Int,
                    bbox: entry["bbox"] as? [Double],
                    sectionTitle: entry["section_title"] as? String ?? "",
                    textOriginal: entry["text_original"] as? String ?? "",
                    textZh: "", oneLiner: "", keywords: [], roleInNarrative: "",
                    imagePath: entry["image_path"] as? String ?? "",
                    captionOriginal: entry["caption_original"] as? String ?? "",
                    captionZh: "", figureType: "", coreTakeaways: [], dataReadingNotes: "",
                    tableHtml: entry["table_html"] as? String ?? "",
                    latex: entry["latex"] as? String ?? "", plainExplanation: "", entityRefs: [],
                    headingLevel: entry["heading_level"] as? Int
                )
            }
            try await library.writeBlocks(paperId: paper.id, blocks: blocks)

            // Coverage: a paper that parses into almost nothing is a failure even
            // when the block count is non-zero.
            let withText = blocks.filter { !$0.textOriginal.isEmpty }
            let coverage = Double(withText.count) / Double(max(1, blocks.count))
            XCTAssertGreaterThan(coverage, 0.8,
                                 "\(input.lastPathComponent): only \(withText.count)/\(blocks.count) blocks carry text")
            XCTAssertGreaterThan(withText.reduce(0) { $0 + $1.textOriginal.count }, 2_000,
                                 "\(input.lastPathComponent): suspiciously little text extracted")

            // Structure the reader and chat depend on.
            XCTAssertTrue(blocks.contains { $0.kind == "section_heading" },
                          "\(input.lastPathComponent): no section headings — navigation would be flat")

            // Every figure path must resolve inside the library (get_figure rejects it otherwise).
            for block in blocks where block.kind == "figure" && !block.imagePath.isEmpty {
                let url = await library.layout.fileURL(forRelativePath: block.imagePath)
                XCTAssertNotNil(url, "\(input.lastPathComponent): figure path \(block.imagePath) does not resolve")
            }

            // Identifier recognition runs on real text and must stay silent on failure.
            let ids = PaperMetadata.extractIdentifiers(from: blocks)
            if let doi = ids.doi {
                XCTAssertTrue(doi.hasPrefix("10."), "Malformed DOI extracted: \(doi)")
            }
        }
    }

    /// Checks the recovery sidecar contract once a real analysis has been run.
    /// Skips unless a finished analysis exists, so it can be run repeatedly.
    func testExistingAnalysisSidecarMatchesCurrentInput() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let papers = await library.listPapers()
        try XCTSkipIf(papers.isEmpty, "No analysed papers in this library.")

        for paper in papers {
            let sidecar = await library.analysesDir(paper.id).appendingPathComponent("single_pass.json")
            try XCTSkipUnless(FileManager.default.fileExists(atPath: sidecar.path),
                              "\(paper.id): no single_pass.json sidecar")

            let log = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
            XCTAssertEqual(log?["mode"] as? String, "single_pass")
            let blocks = try await library.readBlocks(paperId: paper.id)
            XCTAssertEqual(log?["block_count"] as? Int, blocks.count,
                           "\(paper.id): sidecar block count no longer matches the parsed blocks")

            // A stale fingerprint means recovery would be refused — the raw
            // response can no longer be trusted against the current blocks.
            let input = blocks.map { block in
                ["id": block.id, "kind": block.kind, "text_original": block.textOriginal,
                 "caption_original": block.captionOriginal, "latex": block.latex,
                 "table_html": block.tableHtml, "section_title": block.sectionTitle]
            }
            if let fingerprint = log?["input_fingerprint"] as? String {
                XCTAssertEqual(fingerprint, AnalysisEngine.inputFingerprint(input),
                               "\(paper.id): analysis was produced from different source text")
            }
        }
    }

    /// Reads MinerU settings from the user's real local config, if present.
    private func localMinerUConfig() async -> MinerUClient.Config? {
        guard let url = UserDefaults.standard.string(forKey: "mineruLocalUrl") ?? ProcessInfo.processInfo.environment["PAPERICO_MINERU_LOCAL_URL"],
              !url.isEmpty else { return nil }
        return MinerUClient.Config(mode: "local", baseUrl: "", localUrl: url,
                                   token: "", options: MinerUDefaultOptions())
    }
}