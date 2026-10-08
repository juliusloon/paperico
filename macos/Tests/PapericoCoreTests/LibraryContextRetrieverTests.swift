import XCTest
@testable import PapericoCore

final class LibraryContextRetrieverTests: XCTestCase {
    func testRankingExclusionStableTiesAndZeroMatches() {
        var a = PaperListItem.empty(id: "a"), b = PaperListItem.empty(id: "b"), c = PaperListItem.empty(id: "c")
        a.title = "Contrastive Learning"; b.title = a.title; c.tldr = "contrastive learning"
        XCTAssertEqual(LibraryContextRetriever.rank(query: "contrastive", papers: [c,b,a], methods: [], excluding: nil).map { $0.paper.id }, ["a","b","c"])
        XCTAssertEqual(LibraryContextRetriever.rank(query: "contrastive", papers: [a,b,c], methods: [], excluding: "a", limit: 1).first?.paper.id, "b")
        XCTAssertTrue(LibraryContextRetriever.rank(query: "unmentioned", papers: [a], methods: [], excluding: nil).isEmpty)
    }
    func testMetadataAndMethodRecall() {
        var p = PaperListItem.empty(id: "a")
        p.authors = ["Ada Lovelace"]; p.year = 2026; p.venue = "Nature"
        let method = MethodIndexItem(canonicalKey: "m", name: "Triplet", category: "ALGORITHM", definitionZh: "梯度对比", papers: [.init(paperId: p.id, title: "", blockIds: [])], addedAt: "")
        for query in ["Ada", "2026", "Nature", "Triplet", "梯度对比"] {
            XCTAssertEqual(LibraryContextRetriever.rank(query: query, papers: [p], methods: [method], excluding: nil).first?.paper.id, p.id)
        }
    }
    func testStrictSemanticBudget() {
        XCTAssertEqual(LibraryContextRetriever.clipLines("short\n" + String(repeating: "x", count: 100) + "\ntail", budget: 12), "short\ntail")
        XCTAssertLessThanOrEqual(LibraryContextRetriever.clipLines(String(repeating: "heading\n", count: 10000), budget: 2400).count, 2400)
    }
    func testSynthetic100And300PaperRankingPerformance() {
        for count in [100, 300] {
            let papers = (0..<count).map { i -> PaperListItem in
                var p = PaperListItem.empty(id: String(format: "%03d", i)); p.title = "Contrastive molecular learning \(i)"; p.tldr = String(repeating: "Molecular prediction. ", count: 30); return p
            }
            let start = Date()
            let ranked = LibraryContextRetriever.rank(query: "molecular", papers: papers, methods: [], excluding: nil)
            XCTAssertEqual(ranked.count, 4)
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        }
    }
}
