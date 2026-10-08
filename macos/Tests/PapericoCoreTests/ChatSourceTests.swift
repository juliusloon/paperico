import XCTest
@testable import PapericoCore

final class ChatSourceTests: XCTestCase {
    func testTypedSourcesRoundTripAndOrderedValidation() throws {
        var registry = ChatSourceRegistry()
        let p = registry.register(kind: .paper, paperId: "paper", title: "Title")
        let m = registry.register(kind: .method, paperId: "paper", methodKey: "method", title: "Method")
        let b = registry.register(kind: .block, paperId: "paper", blockId: "b0001")
        XCTAssertEqual(registry.register(kind: .paper, paperId: "paper"), p)
        XCTAssertEqual(try JSONDecoder().decode([ChatSourceRef].self, from: JSONEncoder().encode(registry.sources)), registry.sources)
        let answer = "[\(m)] [\(p)] [\(m)] [\(b)] [s999] `[\(p)]`\n```\n[\(b)]\n```"
        XCTAssertEqual(registry.validatedSources(in: answer).map(\.token), [m, p, b])
        XCTAssertTrue(registry.validatedSources(in: "[paper] [b0001]").isEmpty)
    }
    func testLegacyChatWithoutSourceFieldsDecodes() throws {
        let data = Data(#"{"id":"m","sessionId":"s","role":"assistant","content":"old","createdAt":"now"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: data).sourceRefs)
    }
    func testExactBlockTokensAndUnclosedCode() {
        let short = Block(id: "b001", order: 0, kind: "paragraph", pageIdx: nil, bbox: nil,
                          sectionTitle: "", textOriginal: "", textZh: "", oneLiner: "", keywords: [], roleInNarrative: "",
                          imagePath: "", captionOriginal: "", captionZh: "", figureType: "", coreTakeaways: [], dataReadingNotes: "",
                          tableHtml: "", latex: "", plainExplanation: "", entityRefs: [])
        var long = short; long.id = "b0010"
        var paper = PaperListItem.empty(id: "p"); paper.title = "Evidence"
        var registry = ChatSourceRegistry()
        registry.registerCurrent(blocks: [short, long], paperId: paper.id, context: "[b0010]")
        XCTAssertEqual(registry.sources.map(\.blockId), [long.id])
        registry = ChatSourceRegistry()
        let translated = registry.tokenize("[b0010,b001]", paper: paper, blocks: [short, long])
        XCTAssertEqual(translated, "[s002,s001]")
        XCTAssertEqual(registry.sources.map(\.blockId), [short.id, long.id])
        XCTAssertTrue(registry.validatedSources(in: "`unfinished [s001]").isEmpty)
    }

}
