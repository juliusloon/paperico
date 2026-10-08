import XCTest
@testable import PapericoCore

final class AnalysisMetadataTests: XCTestCase {
    func testSummaryPersistsWhileManualTitleSurvives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\nsummary".utf8), fileName: "summary.pdf", projectId: nil)
        _ = try await library.renamePaper(id: paper.id, title: "My title")
        try await library.updatePaper { record in
            AnalysisEngine.applyPaperSummary(["title": "Model title", "title_zh": "译名", "tldr": "摘要"], to: &record)
        }
        let stored = await library.paper(id: paper.id)
        XCTAssertEqual(stored?.title, "My title")
        XCTAssertEqual(stored?.titleZh, "译名")
        XCTAssertEqual(stored?.tldr, "摘要")
        XCTAssertEqual(stored?.metaSource, MetaSource.manual)
    }

    func testAutomaticAndLocalTitlesMayBeReplaced() {
        for source in [MetaSource.local, MetaSource.auto] {
            var paper = PaperListItem.empty(id: "paper")
            paper.title = "Previous"
            paper.metaSource = source
            AnalysisEngine.applyPaperSummary(["title": "Model title"], to: &paper)
            XCTAssertEqual(paper.title, "Model title")
        }
    }
}
