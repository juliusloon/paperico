import Foundation

/// A revision keeps the original conversation intact and rebuilds only the selected turn onward.
enum ChatRevision {
    struct Turn: Sendable {
        let history: [ChatMessage]
        let content: String
        let context: [AttachedContext]?
    }
    static func editing(_ session: ChatSession, messageId: String, content: String) -> Turn? {
        guard let index = session.messages.firstIndex(where: { $0.id == messageId && $0.role == "user" }),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Turn(history: Array(session.messages[..<index]), content: content, context: session.messages[index].attachedContext)
    }
    static func regenerating(_ session: ChatSession, assistantId: String) -> Turn? {
        guard let index = session.messages.firstIndex(where: { $0.id == assistantId && $0.role == "assistant" }),
              let user = session.messages[..<index].last(where: { $0.role == "user" }) else { return nil }
        return editing(session, messageId: user.id, content: user.content)
    }
}
