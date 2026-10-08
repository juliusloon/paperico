import XCTest
@testable import PapericoCore

/// MCP `get_paper` must surface metadata backfilled by Track A (doi/authors/year)
/// without touching the schema snapshot — the fields already ride along inside
/// `PaperListItem`, this test just locks the contract.
final class LibraryAutomationMetadataTests: XCTestCase {
    func testGetPaperReturnsBackfilledMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\nmetadata".utf8),
                                                fileName: "meta.pdf", projectId: nil)
        let applied = try await library.applyMetadata(paperId: paper.id, .init(
            title: "Attention Is All You Need",
            authors: ["Vaswani", "Shazeer"],
            year: 2017,
            venue: "NeurIPS",
            doi: "10.48550/arXiv.1706.03762",
            arxivId: "1706.03762"))
        XCTAssertTrue(applied)

        let output = try await library.automationQuery(
            "get_paper",
            arguments: Data(AnalysisEngine.jsonString(["paper_id": paper.id]).utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: output.json) as? [String: Any])
        let detail = try XCTUnwrap(object["paper"] as? [String: Any])
        XCTAssertEqual(detail["title"] as? String, "Attention Is All You Need")
        XCTAssertEqual(detail["authors"] as? [String], ["Vaswani", "Shazeer"])
        XCTAssertEqual(detail["year"] as? Int, 2017)
        XCTAssertEqual(detail["doi"] as? String, "10.48550/arXiv.1706.03762")
        XCTAssertEqual(detail["arxiv_id"] as? String, "1706.03762")
        XCTAssertEqual(detail["meta_source"] as? String, "auto")
        // Automation must not mark the paper opened.
        let after = await library.paper(id: paper.id)
        XCTAssertNil(after?.lastOpenedAt)
    }
}
