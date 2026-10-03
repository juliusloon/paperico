import XCTest
@testable import PapericoCore

final class ChatRevisionTests: XCTestCase {
    private func session() -> ChatSession {
        let context = AttachedContext(type: "text_selection", refBlockId: "b1", refEntityId: nil, snippet: "Evidence")
        let messages = [
            ChatMessage(id: "u1", sessionId: "s1", role: "user", content: "第一问", attachedContext: nil, citedBlockIds: nil, createdAt: ""),
            ChatMessage(id: "a1", sessionId: "s1", role: "assistant", content: "第一答", attachedContext: nil, citedBlockIds: ["b1"], createdAt: ""),
            ChatMessage(id: "u2", sessionId: "s1", role: "user", content: "第二问", attachedContext: [context], citedBlockIds: nil, createdAt: ""),
            ChatMessage(id: "a2", sessionId: "s1", role: "assistant", content: "第二答", attachedContext: nil, citedBlockIds: nil, createdAt: "", generationState: "stopped")
        ]
        return ChatSession(id: "s1", paperId: "p1", title: "研究", messages: messages, createdAt: "")
    }

    func testEditingRetainsEarlierTurnsAndSelectedEvidence() throws {
        let original = session()
        let turn = try XCTUnwrap(ChatRevision.editing(original, messageId: "u2", content: "修订问题"))
        XCTAssertEqual(turn.history.map(\.id), ["u1", "a1"])
        XCTAssertEqual(turn.context, original.messages[2].attachedContext)
        XCTAssertEqual(turn.content, "修订问题")
        XCTAssertEqual(original.messages.last?.content, "第二答")
        XCTAssertEqual(original.messages.count, 4)
    }

    func testRegenerationSelectsCorrespondingUserTurn() throws {
        let original = session()
        let turn = try XCTUnwrap(ChatRevision.regenerating(original, assistantId: "a1"))
        XCTAssertTrue(turn.history.isEmpty)
        XCTAssertEqual(turn.content, "第一问")
        XCTAssertNil(turn.context)
        XCTAssertNil(ChatRevision.editing(original, messageId: "a1", content: "不能编辑回答"))
        XCTAssertNil(ChatRevision.editing(original, messageId: "u1", content: " \n"))
        XCTAssertNil(ChatRevision.regenerating(original, assistantId: "missing"))
    }

    func testOldMessagesDecodeWithoutGenerationState() throws {
        let data = Data(#"{"id":"m1","sessionId":"s1","role":"assistant","content":"answer","createdAt":"now"}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(message.generationState)
        XCTAssertEqual(message.content, "answer")
    }
}
