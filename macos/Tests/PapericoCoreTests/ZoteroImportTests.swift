import XCTest
@testable import PapericoCore

final class ZoteroImportTests: XCTestCase {
    func testSyntheticFolderCountsAndAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bib = """
        @article{a, title={Authoritative}, author={User, Ada}, year={2020}, journal={Venue}, doi={10.5555/a}, file={a.pdf}}
        @article{b, title={Duplicate}, doi={10.5555/a}, file={b.pdf}}
        @article{missing, title={Unavailable}, file={missing.pdf}}
        """
        try bib.write(to: folder.appendingPathComponent("export.bib"), atomically: true, encoding: .utf8)
        for name in ["a", "b", "orphan"] {
            try Data("%PDF-1.7\n\(name)".utf8).write(to: folder.appendingPathComponent(name + ".pdf"))
        }
        try Data("broken".utf8).write(to: folder.appendingPathComponent("broken.pdf"))
        let library = PaperLibrary(root: root.appendingPathComponent("library"))
        try await library.load()
        let report = try await ZoteroImport.run(folder: folder, projectId: nil, library: library)
        XCTAssertEqual(report.imported.count, 2)
        XCTAssertEqual(report.withoutMetadata, ["orphan.pdf"])
        XCTAssertEqual(report.duplicates.count, 1)
        XCTAssertEqual(report.unmatched.count, 1)
        XCTAssertEqual(report.failures.count, 1)
        let paper = try XCTUnwrap(report.imported.first { $0.title == "Authoritative" })
        XCTAssertEqual(paper.metaSource, MetaSource.manual)
        XCTAssertEqual(paper.authors, ["Ada User"])
        XCTAssertEqual(paper.year, 2020)
        XCTAssertEqual(paper.venue, "Venue")
        XCTAssertEqual(paper.status, "uploaded")
        let second = try await ZoteroImport.run(folder: folder, projectId: nil, library: library)
        XCTAssertEqual(second.imported.count, 0)
        XCTAssertEqual(second.duplicates.count, 3)
    }

    func testImportedAuthoritySurvivesRecognitionAndAnalysis() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let authority = PaperMetadata.Metadata(title: "Zotero title", authors: ["Ada"], year: 2021, venue: "Journal", doi: "10.5555/bib")
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\nauthority".utf8), fileName: "authority.pdf", projectId: nil, metadata: authority)
        let block = Block(id: "b0001", order: 0, kind: "paragraph", pageIdx: 0, bbox: nil, sectionTitle: "",
                          textOriginal: "DOI:10.5555/auto", textZh: "", oneLiner: "", keywords: [], roleInNarrative: "",
                          imagePath: "", captionOriginal: "", captionZh: "", figureType: "", coreTakeaways: [],
                          dataReadingNotes: "", tableHtml: "", latex: "", plainExplanation: "", entityRefs: [])
        _ = try await MetadataRecognition.run([block], actions: MetadataRecognition.actions(library: library, paperId: paper.id, lookup: { _ in
            XCTFail("Authority must skip automatic recognition")
            return .init(title: "Automatic title")
        }))
        try await library.updatePaper { record in
            AnalysisEngine.applyPaperSummary(["title": "LLM title", "title_zh": "模型译名", "tldr": "模型摘要"], to: &record)
        }
        let stored = await library.paper(id: paper.id)
        XCTAssertEqual(stored?.title, authority.title)
        XCTAssertEqual(stored?.authors, authority.authors)
        XCTAssertEqual(stored?.year, authority.year)
        XCTAssertEqual(stored?.venue, authority.venue)
        XCTAssertEqual(stored?.doi, authority.doi)
        XCTAssertEqual(stored?.metaSource, MetaSource.manual)
        XCTAssertEqual(stored?.titleZh, "模型译名")
    }

    func testEmptyAndMultipleBibFoldersFail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ZoteroImport.scan(folder: root))
        for name in ["a.bib", "b.bib"] { try Data().write(to: root.appendingPathComponent(name)) }
        XCTAssertThrowsError(try ZoteroImport.scan(folder: root))
    }

    func testExactPairingWinsAndAmbiguousFuzzyIsUnmatched() {
        let root = URL(fileURLWithPath: "/tmp/export")
        let a = root.appendingPathComponent("same-a.pdf"), b = root.appendingPathComponent("same-b.pdf")
        let entries = ZoteroBibParser.parse("@misc{same, title={same}}\n@misc{exact, file={same-a.pdf}}")
        let plan = ZoteroImport.pair(entries: entries, pdfs: [a, b], folder: root)
        XCTAssertEqual(plan.pairs.first?.entry.key, "exact")
        XCTAssertEqual(plan.pairs.count, 2)
        let ambiguous = ZoteroImport.pair(entries: [entries[0]], pdfs: [a, b], folder: root)
        XCTAssertEqual(ambiguous.unmatched.count, 1)
        XCTAssertEqual(ambiguous.withoutMetadata.count, 2)
    }
}
