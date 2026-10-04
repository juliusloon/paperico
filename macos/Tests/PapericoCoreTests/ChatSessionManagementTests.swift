import XCTest
@testable import PapericoCore

final class ChatSessionManagementTests: XCTestCase {
    func testRenameAndDeletePersistWithoutChangingOtherMessagesOrExportedNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\ntest".utf8), fileName: "test.pdf", projectId: nil)
        let first = ChatSession(id: "s1", paperId: paper.id, title: "原名称", messages: [
            ChatMessage(id: "m1", sessionId: "s1", role: "user", content: "保留问题", attachedContext: nil,
                        citedBlockIds: nil, createdAt: "now")], createdAt: "now")
        let second = ChatSession(id: "s2", paperId: paper.id, title: "另一对话", messages: [], createdAt: "later")
        try await library.saveChatSession(paperId: paper.id, session: first)
        try await library.saveChatSession(paperId: paper.id, session: second)
        let note = Note(id: "exported", paperId: paper.id, title: "已导出笔记", markdownContent: "保存的证据",
                        createdAt: "now", updatedAt: "now")
        try await library.addNote(paperId: paper.id, note: note)
        try await library.renameChatSession(paperId: paper.id, sessionId: first.id, title: "  手动名称  \n")
        let renamed = try await library.chatSession(paperId: paper.id, sessionId: first.id)
        XCTAssertEqual(renamed?.title, "手动名称")
        XCTAssertEqual(renamed?.messages, first.messages)
        do {
            try await library.renameChatSession(paperId: paper.id, sessionId: first.id, title: " \n")
            XCTFail("Empty title must be rejected")
        } catch {}
        try await library.deleteChatSession(paperId: paper.id, sessionId: first.id)
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let sessions = try await reopened.chatSessions(paperId: paper.id)
        XCTAssertEqual(sessions, [second])
        let notes = try await reopened.notes(paperId: paper.id)
        XCTAssertEqual(notes, [note])
        // A stale delete is harmless and cannot remove a different session.
        try await reopened.deleteChatSession(paperId: paper.id, sessionId: first.id)
        let afterStaleDelete = try await reopened.chatSessions(paperId: paper.id)
        XCTAssertEqual(afterStaleDelete, [second])
    }

    func testSessionOperationsAreScopedToTheirPaper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let a = try await library.importPDF(fileData: Data("%PDF-1.7\na".utf8), fileName: "a.pdf", projectId: nil)
        let b = try await library.importPDF(fileData: Data("%PDF-1.7\nb".utf8), fileName: "b.pdf", projectId: nil)
        let session = ChatSession(id: "same-id", paperId: a.id, title: "A 的对话", messages: [], createdAt: "now")
        try await library.saveChatSession(paperId: a.id, session: session)
        try await library.deleteChatSession(paperId: b.id, sessionId: session.id)
        do {
            try await library.renameChatSession(paperId: b.id, sessionId: session.id, title: "错误目标")
            XCTFail("Missing session must be rejected")
        } catch {}
        let retained = try await library.chatSession(paperId: a.id, sessionId: session.id)
        XCTAssertEqual(retained, session)
    }
}
