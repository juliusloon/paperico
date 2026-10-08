import XCTest
@testable import PapericoCore

final class ChatContextTests: XCTestCase {
    private func block(id: String, text: String) -> Block {
        Block(id: id, order: 0, kind: "paragraph", pageIdx: 0, bbox: nil, sectionTitle: "",
              textOriginal: text, textZh: "", oneLiner: "", keywords: [], roleInNarrative: "",
              imagePath: "", captionOriginal: "", captionZh: "", figureType: "", coreTakeaways: [],
              dataReadingNotes: "", tableHtml: "", latex: "", plainExplanation: "", entityRefs: [])
    }

    func testPromptIncludesOnlyPresentMetadata() {
        let prompt = AnalysisEngine.buildChatSystemPrompt(title: "Title", titleZh: "", domainTags: [], tldr: "", paperContext: "",
                                                         authors: ["Ada"], year: 2026, venue: "Nature", doi: "10.1234/test")
        XCTAssertTrue(prompt.contains("作者：Ada · 年份：2026 · 期刊：Nature · DOI：10.1234/test"))
        let empty = AnalysisEngine.buildChatSystemPrompt(title: "Title", titleZh: "", domainTags: [], tldr: "", paperContext: "")
        XCTAssertTrue(empty.contains("标题：Title / \n领域标签："))
        XCTAssertFalse(empty.contains("作者："))
        XCTAssertFalse(empty.contains("DOI："))
    }

    func testReferencedParagraphIncludesEvidenceBeyondPreview() {
        let source = String(repeating: "Background. ", count: 80) + "ACA combines regression with triplet contrastive learning."
        let context = AttachedContext(type: "text_selection", refBlockId: "b0009", refEntityId: nil,
                                      snippet: String(source.prefix(240)))
        let result = ChatContextBuilder.buildAttachedText([context], blocks: [block(id: "b0009", text: source)], entities: [])
        XCTAssertTrue(result.contains("[引用段落 b0009]"))
        XCTAssertTrue(result.contains("ACA combines regression with triplet contrastive learning."))
    }

    func testLargeSelectionsHaveBoundedTotalContext() {
        let text = String(repeating: "x", count: 20000)
        let contexts = (0..<10).map { _ in
            AttachedContext(type: "text_selection", refBlockId: nil, refEntityId: nil, snippet: text)
        }
        let result = ChatContextBuilder.buildAttachedText(contexts, blocks: [], entities: [])
        XCTAssertLessThanOrEqual(result.count, ChatContextBuilder.attachedContextBudget + 1)
    }
}
