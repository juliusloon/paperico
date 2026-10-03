import XCTest
@testable import PapericoCore

final class PaperOutlineTests: XCTestCase {
    private func block(_ id: String, _ title: String, heading: Bool = true, level: Int? = nil) -> Block {
        Block(id: id, order: 0, kind: heading ? "section_heading" : "paragraph", pageIdx: 0,
              bbox: nil, sectionTitle: "", textOriginal: title, textZh: "", oneLiner: "",
              keywords: [], roleInNarrative: "", imagePath: "", captionOriginal: "", captionZh: "",
              figureType: "", coreTakeaways: [], dataReadingNotes: "", tableHtml: "", latex: "",
              plainExplanation: "", entityRefs: [], headingLevel: level)
    }

    func testSectionsSubsectionsAndEvidenceHaveCorrectParents() {
        let entries = PaperOutline.entries([
            block("intro", "Introduction"),
            block("e1", "Background evidence", heading: false),
            block("method", "2 Methods"),
            block("sub", "2.1 Training"),
            block("e2", "Training evidence", heading: false),
            block("sub2", "2.2 Evaluation"),
            block("results", "3 Results")
        ])
        XCTAssertEqual(entries.map(\.level), [1, 2, 1, 2, 3, 2, 1])
        XCTAssertEqual(entries.map(\.parentBlockId), [nil, "intro", nil, "method", "sub", "method", nil])
    }

    func testParserAndLegacyMarkdownHeadingLevelsArePreserved() {
        let entries = PaperOutline.entries([
            block("section", "Methods", level: 1),
            block("parsed", "Model architecture", level: 2),
            block("old", "### Ablation"),
            block("deep", "2.1.3.1 Sensitivity"),
            block("evidence", "Evidence", heading: false)
        ])
        XCTAssertEqual(entries.map(\.level), [1, 2, 3, 4, 5])
        XCTAssertEqual(entries.last?.parentBlockId, "deep")
    }

    func testExistingLibraryBlocksDecodeWithoutHeadingLevel() throws {
        let source = block("old", "Introduction")
        let encoded = try JSONEncoder().encode(source)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "headingLevel")
        let decoded = try JSONDecoder().decode(Block.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.headingLevel)
        XCTAssertEqual(PaperOutline.entries([decoded]).first?.level, 1)
    }

    func testFlatResearchHeadingsRecoverChaptersAndSubsections() {
        let entries = PaperOutline.entries([
            block("results", "Results", level: 2),
            block("model", "Equipping graph neural network models with ACA", level: 2),
            block("evidence", "Model evidence", heading: false),
            block("methods", "Methods", level: 2),
            block("datasets", "Molecular property prediction datasets", level: 2)
        ])
        XCTAssertEqual(entries.map(\.level), [1, 2, 3, 1, 2])
        XCTAssertEqual(entries.map(\.parentBlockId), [nil, "results", "model", nil, "methods"])
    }
}
