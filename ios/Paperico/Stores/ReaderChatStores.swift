import Foundation
import Observation

// MARK: - ReaderStore (mirrors useReaderStore)

enum BilingualMode: String, Hashable, CaseIterable {
    case original, translation, bilingual
}

struct AttachedContextItem: Hashable, Sendable {
    var context: AttachedContext
    var displaySnippet: String
}

/// T2.3: a pending "locate this block on the PDF canvas" request; the token
/// increments so re-clicking the same block re-triggers the jump.
struct PendingPdfFocus: Equatable {
    var blockId: String
    var token: Int
}

@MainActor
@Observable
final class ReaderStore {
    private let client: ApiClient

    var paper: PaperDetail?
    var error = ""
    var loading = false

    // UI state (mirrors the store fields)
    var bilingualMode: BilingualMode = .bilingual
    var fontSize: CGFloat = 18
    var leftPanelCollapsed = false
    var leftPanelDensity: String = "detailed" // compact | detailed
    var activeBlockId: String?
    var highlightedEntities: [String] = []
    var selectedText = ""
    var attachedContext: [AttachedContext] = []

    // Native scroll coordination
    var pendingScrollTarget: String?
    var pendingScrollAnchorCentered = false
    var flashBlockId: String?
    // Mirrored from ReadingArea so chat chips / MetaCard / outline jumps know
    // whether the PDF canvas is the active surface.
    var viewMode: ReaderViewMode = .text
    var pendingPdfFocus: PendingPdfFocus?

    private var readerRequestVersion = 0

    init(client: ApiClient) {
        self.client = client
    }

    func fetchPaper(id: String) async {
        readerRequestVersion += 1
        let version = readerRequestVersion
        loading = true
        paper = nil
        error = ""
        attachedContext = []
        activeBlockId = nil
        pendingPdfFocus = nil
        do {
            let detail = try await client.papersGet(id: id)
            if version == readerRequestVersion {
                paper = detail
                loading = false
            }
        } catch {
            if version == readerRequestVersion {
                loading = false
                self.error = ApiFailure.wrap(error).errorDescription ?? "论文加载失败，请重试。"
            }
        }
    }

    func refreshPaper(id: String) async {
        let version = readerRequestVersion
        guard let detail = try? await client.papersGet(id: id) else { return }
        if version == readerRequestVersion, paper?.paper.id == id {
            paper = detail
        }
    }

    func setBilingualMode(_ mode: BilingualMode) {
        bilingualMode = mode
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = min(23, max(13, size))
    }

    func toggleLeftPanel() {
        leftPanelCollapsed.toggle()
    }

    func setLeftPanelDensity(_ d: String) {
        leftPanelDensity = d
    }

    func setActiveBlock(_ id: String?) {
        activeBlockId = id
    }

    func highlightEntities(_ ids: [String]) {
        highlightedEntities = ids
    }

    func setSelectedText(_ text: String) {
        selectedText = text
    }

    func addAttachedContext(_ ctx: AttachedContext) {
        let duplicate = attachedContext.contains { item in
            item.type == ctx.type
                && item.refEntityId == ctx.refEntityId
                && item.refBlockId == ctx.refBlockId
                && item.snippet == ctx.snippet
        }
        if !duplicate {
            attachedContext.append(ctx)
        }
    }

    func removeAttachedContext(at index: Int) {
        guard attachedContext.indices.contains(index) else { return }
        attachedContext.remove(at: index)
    }

    func clearAttachedContext() {
        attachedContext = []
    }

    // MARK: scroll coordination

    /// Scrolls the reading area to a block and flashes it for 1.8s (mirrors .block-highlighted).
    /// In PDF mode the jump is redirected to the PDF canvas (T2.3).
    func scrollToBlock(_ blockId: String, centered: Bool = false) {
        activeBlockId = blockId
        if viewMode == .pdf {
            requestPdfFocus(blockId)
            return
        }
        pendingScrollTarget = blockId
        pendingScrollAnchorCentered = centered
    }

    func setViewMode(_ mode: ReaderViewMode) {
        viewMode = mode
    }

    func requestPdfFocus(_ blockId: String) {
        pendingPdfFocus = PendingPdfFocus(blockId: blockId, token: (pendingPdfFocus?.token ?? 0) + 1)
    }

    func consumeScrollTarget() {
        if let target = pendingScrollTarget {
            pendingScrollTarget = nil
            flashBlockId = target
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if flashBlockId == target { flashBlockId = nil }
            }
        }
    }
}

// MARK: - ChatStore (mirrors useChatStore)

@MainActor
@Observable
final class ChatStore {
    private let client: ApiClient

    var sessions: [ChatSession] = []
    var currentSession: ChatSession?
    var streaming = false
    var streamContent = ""

    init(client: ApiClient) {
        self.client = client
    }

    func fetchSessions(paperId: String) async {
        sessions = (try? await client.chatListSessions(paperId: paperId)) ?? sessions
    }

    func loadSession(paperId: String, sessionId: String) async {
        do {
            currentSession = try await client.chatGetSession(paperId: paperId, sessionId: sessionId)
        } catch {
            // Keep the current session; the error is visible through the API layer.
        }
    }

    /// Streams a reply; SSE handling mirrors the async generator loop in useChatStore.sendMessage.
    func sendMessage(paperId: String, content: String, attachedContext: [AttachedContext]?) async {
        let session = currentSession
        streaming = true
        streamContent = ""

        let userMessage = ChatMessage(
            id: "temp-\(Date().timeIntervalSince1970 * 1000)",
            sessionId: session?.id ?? "",
            role: "user",
            content: content,
            attachedContext: attachedContext,
            citedBlockIds: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        if let session {
            var updated = session
            updated.messages.append(userMessage)
            currentSession = updated
        }

        var fullContent = ""
        var sessionId = session?.id
        var assistantMessageId = ""
        var citedBlockIds: [String] = []

        do {
            for try await event in client.chatSend(paperId: paperId, content: content, sessionId: sessionId, attachedContext: attachedContext) {
                if let chunk = event.content, !chunk.isEmpty {
                    fullContent += chunk
                    streamContent = fullContent
                }
                if let sid = event.sessionId, !sid.isEmpty { sessionId = sid }
                if let mid = event.messageId, !mid.isEmpty {
                    assistantMessageId = mid
                    citedBlockIds = event.citedBlockIds ?? []
                }
            }
        } catch {
            let message = ApiFailure.wrap(error).errorDescription ?? "未知错误"
            fullContent += "\n\n[错误: \(message)]"
            streamContent = fullContent
        }

        let assistantMessage = ChatMessage(
            id: assistantMessageId.isEmpty ? "msg-\(Date().timeIntervalSince1970 * 1000)" : assistantMessageId,
            sessionId: sessionId ?? "",
            role: "assistant",
            content: fullContent,
            attachedContext: nil,
            citedBlockIds: citedBlockIds,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )

        var messages = session?.messages ?? []
        messages.append(userMessage)
        messages.append(assistantMessage)

        currentSession = ChatSession(
            id: sessionId ?? "",
            paperId: paperId,
            title: String(content.prefix(50)),
            messages: messages,
            createdAt: session?.createdAt ?? ISO8601DateFormatter().string(from: Date())
        )
        streaming = false
        streamContent = ""

        await fetchSessions(paperId: paperId)
    }

    func newSession() {
        currentSession = nil
        streamContent = ""
    }
}
