import XCTest
@testable import PapericoCore

final class ZoteroBibParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> [ZoteroBibParser.Entry] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Zotero")
        return ZoteroBibParser.parse(try String(contentsOf: root.appendingPathComponent(name + ".bib"), encoding: .utf8))
    }
    func testNativeShapeFields() throws {
        let entries = try fixture("native")
        XCTAssertEqual(entries.count, 1)
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(e.key, "attention")
        XCTAssertEqual(e.metadata.title, "Attention Is All You Need")
        XCTAssertEqual(e.metadata.authors, ["Ashish Vaswani", "Noam Shazeer"])
        XCTAssertEqual(e.metadata.year, 2017)
        XCTAssertEqual(e.metadata.venue, "NeurIPS")
        XCTAssertEqual(e.metadata.doi, "10.5555/3295222.3295349")
        XCTAssertEqual(e.files, ["files/attention.pdf"])
        XCTAssertNil(e.error)
    }
    func testBetterBibTeXShape() throws {
        let e = try XCTUnwrap(fixture("better-bibtex").first)
        XCTAssertEqual(e.metadata.title, "A Contrastive Method")
        XCTAssertEqual(e.metadata.authors, ["Jane Doe", "Research and Development"])
        XCTAssertEqual(e.metadata.year, 2025)
        XCTAssertEqual(e.metadata.venue, "ICLR")
        XCTAssertEqual(e.metadata.arxivId, "2501.01234")
        XCTAssertEqual(e.files, ["files/contrast.pdf"])
    }
    func testEdgesAndMalformedRecovery() throws {
        let entries = try fixture("edges")
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].type, "misc")
        XCTAssertEqual(entries[0].metadata.title, "Nested GPU methods & data")
        XCTAssertEqual(entries[0].metadata.authors, ["José García"])
        XCTAssertEqual(entries[0].metadata.year, 2026)
        XCTAssertEqual(entries[0].metadata.venue, "Science")
        XCTAssertEqual(entries[0].files, ["/tmp/edge paper.pdf"])
        XCTAssertEqual(entries[1].metadata.title, "")
        XCTAssertNotNil(entries[2].error)
        XCTAssertEqual(entries[3].metadata.title, "Recovered")
    }
    func testMalformedInputsTerminate() {
        for value in ["", "@", "@article", "@article{", "@article{x, title=}", "@article{x, title=\"bad", "% @article{ignored}"] {
            _ = ZoteroBibParser.parse(value)
        }
        XCTAssertEqual(ZoteroBibParser.attachmentPaths("plain.pdf;:dir/b.pdf:PDF"), ["plain.pdf", "dir/b.pdf"])
    }
}
