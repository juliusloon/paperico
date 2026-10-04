import XCTest
@testable import PapericoCore

final class ChatCitationTests: XCTestCase {
    func testInlineCitationsRetainPositionsAndRepeatedReferences() {
        let text = "依据 🔬 [bf349f7-0003]，再对照 [bf349f7-0013] 与 [bf349f7-0003]。"
        let matches = ChatCitation.matches(in: text, validIds: ["bf349f7-0003", "bf349f7-0013"])
        XCTAssertEqual(matches.map(\.blockId), ["bf349f7-0003", "bf349f7-0013", "bf349f7-0003"])
        for match in matches { XCTAssertEqual((text as NSString).substring(with: match.range), "[" + match.blockId + "]") }
    }
    func testUnvalidatedOrPartialIdsRemainOrdinaryText() {
        XCTAssertEqual(ChatCitation.matches(in: "[missing] [b001] [b002", validIds: ["b001", "b002"]).map(\.blockId), ["b001"])
        XCTAssertTrue(ChatCitation.matches(in: "[b001]", validIds: []).isEmpty)
    }
}
