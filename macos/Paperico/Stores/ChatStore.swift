import Foundation
import Observation
import OSLog

private let chatLog = Logger(subsystem: "com.paperico.app", category: "chat")

// MARK: - ChatStore (mirrors useChatStore)

@MainActor
@Observable
final class ChatStore {
    private let library: PaperLibrary
    private let settings: SettingsStore

    var sessions: [ChatSession] = []
    var error = ""
    var currentSession: ChatSession?
    var streaming = false
    private(set) var preparingRevision = false
    private(set) var updatingSession = false
    var busy: Bool { streaming || preparingRevision || updatingSession }
    var streamContent = ""
    var streamSources: [ChatSourceRef] = []
    var agentActivity = ""
    var libraryPaperCount = 0
    var libraryQueryCount = 0
    @ObservationIgnored private var rememberedSessions: [String: String] = [:]
    var pendingMessage: ChatMessage?
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    private var stopRequested = false
    private var activePaperId: String?
    private var requestVersion = UUID()
    /// 流式开始时刻，用于停止请求的"武装期"（见 stopGenerating）。
    @ObservationIgnored private var streamingBeganAt: Date?

    init(library: PaperLibrary, settings: SettingsStore) {
        self.library = library
        self.settings = settings
    }

    func bind(to paperId: String) {
        guard activePaperId != paperId else { return }
        if let activePaperId, let session = currentSession { rememberedSessions[activePaperId] = session.id }
        generationTask?.cancel()
        generationTask = nil
        activePaperId = paperId
        requestVersion = UUID()
        sessions = []
        currentSession = nil
        streaming = false
        preparingRevision = false
        updatingSession = false
        streamContent = ""
        streamSources = []; agentActivity = ""; libraryPaperCount = 0; libraryQueryCount = 0
        pendingMessage = nil
        error = ""
    }

    func fetchSessions(paperId: String) async {
        bind(to: paperId)
        let version = requestVersion
        do {
            let loaded = try await library.chatSessions(paperId: paperId)
            guard version == requestVersion else { return }
            sessions = loaded
            if currentSession == nil, let id = rememberedSessions[paperId] {
                currentSession = loaded.first { $0.id == id }
            }
        } catch {
            guard version == requestVersion else { return }
            self.error = ApiFailure.wrap(error).localizedDescription
        }
    }

    func loadSession(paperId: String, sessionId: String) async {
        guard !busy else { return }
        bind(to: paperId)
        let version = requestVersion
        do {
            let loaded = try await library.chatSession(paperId: paperId, sessionId: sessionId)
            guard version == requestVersion else { return }
            currentSession = loaded
        } catch {
            guard version == requestVersion else { return }
            self.error = ApiFailure.wrap(error).localizedDescription
        }
    }

    func renameSession(paperId: String, sessionId: String, title: String) async -> Bool {
        guard !busy, activePaperId == paperId else { return false }
        let version = requestVersion
        updatingSession = true
        defer { if version == requestVersion { updatingSession = false } }
        do {
            try await library.renameChatSession(paperId: paperId, sessionId: sessionId, title: title)
            let loaded = try await library.chatSessions(paperId: paperId)
            guard version == requestVersion else { return false }
            sessions = loaded
            if currentSession?.id == sessionId { currentSession = loaded.first { $0.id == sessionId } }
            return true
        } catch {
            guard version == requestVersion else { return false }
            self.error = ApiFailure.wrap(error).localizedDescription
            return false
        }
    }

    func deleteSession(paperId: String, sessionId: String) async {
        guard !busy, activePaperId == paperId else { return }
        let version = requestVersion
        updatingSession = true
        defer { if version == requestVersion { updatingSession = false } }
        do {
            try await library.deleteChatSession(paperId: paperId, sessionId: sessionId)
            let loaded = try await library.chatSessions(paperId: paperId)
            guard version == requestVersion else { return }
            sessions = loaded
            if currentSession?.id == sessionId {
                currentSession = nil
                streamContent = ""
                streamSources = []; agentActivity = ""; libraryPaperCount = 0; libraryQueryCount = 0
                pendingMessage = nil
            }
        } catch {
            guard version == requestVersion else { return }
            self.error = ApiFailure.wrap(error).localizedDescription
        }
    }

    /// 流式问答:走 ChatService(本地会话持久化 + 直连模型),SSE 事件语义与旧后端一致。
    func sendMessage(paperId: String, content: String, attachedContext: [AttachedContext]?) async {
        guard !busy else { return }
        bind(to: paperId)
        let version = requestVersion
        let session = currentSession
        error = ""
        streaming = true
        stopRequested = false
        streamingBeganAt = Date()
        streamContent = ""
        streamSources = []; agentActivity = ""; libraryPaperCount = 0; libraryQueryCount = 0

        let userMessage = ChatMessage(
            id: "temp-\(Date().timeIntervalSince1970 * 1000)",
            sessionId: session?.id ?? "",
            role: "user",
            content: content,
            attachedContext: attachedContext,
            citedBlockIds: nil,
            // Single timestamp source: PaperLibrary.now() is the only fixed-width
            // (24-char, RFC3339 ms) formatter. This optimistic message is replaced by
            // the authoritative on-disk session after the stream ends, but any future
            // path that persists it directly must not reintroduce a 20-char value.
            createdAt: PaperLibrary.now()
        )
        if let session {
            var updated = session
            updated.messages.append(userMessage)
            currentSession = updated
        } else {
            pendingMessage = userMessage
        }

        var fullContent = ""
        var sessionId = session?.id

        do {
            let chatConfig = settings.llmConfig(for: .chat)
            let stream = ChatService.send(
                paperId: paperId, content: content, sessionId: sessionId,
                attachedContext: attachedContext, library: library, llm: chatConfig,
                onTask: { [weak self] task in self?.generationTask = task },
                allowLibraryContext: LocalPrefs.allowLibraryChat,
                onToolsRejected: { [weak self] in self?.settings.invalidateTools(for: chatConfig) }
            )
            for try await event in stream {
                guard version == requestVersion else { return }
                if let sources = event.sourceRefs { streamSources = sources }
                if let activity = event.activity { agentActivity = activity }
                if let count = event.libraryPaperCount { libraryPaperCount = count }
                if let count = event.libraryQueryCount { libraryQueryCount = count }
                if let chunk = event.content, !chunk.isEmpty {
                    fullContent += chunk
                    streamContent = fullContent
                }
                if let sid = event.sessionId, !sid.isEmpty {
                    sessionId = sid
                    if currentSession == nil {
                        var question = userMessage; question.sessionId = sid
                        currentSession = ChatSession(id: sid, paperId: paperId, title: "新对话",
                                                     messages: [question], createdAt: question.createdAt)
                        pendingMessage = nil
                    }
                }
                if let title = event.sessionTitle { currentSession?.title = title }
            }
        } catch {
            guard version == requestVersion else { return }
            if !stopRequested && !(error is CancellationError) { self.error = ApiFailure.wrap(error).localizedDescription }
        }

        guard version == requestVersion else { return }
        // Reload canonical IDs/content; ChatService is the single persistence owner.
        if let sessionId {
            do {
                let loaded = try await library.chatSession(paperId: paperId, sessionId: sessionId)
                guard version == requestVersion else { return }
                currentSession = loaded
            }
            catch { self.error = ApiFailure.wrap(error).localizedDescription }
        }
        guard version == requestVersion else { return }
        streaming = false
        streamingBeganAt = nil
        generationTask = nil
        streamContent = ""
        streamSources = []; agentActivity = ""
        pendingMessage = nil
        await fetchSessions(paperId: paperId)
    }

    /// 发送后的一小段时间内忽略停止请求。发送/停止共用的双态按钮（以及 Enter、Esc）
    /// 在流式刚开始的数百毫秒内被二次触发时，本意几乎都是"刚才到底发出去没有"的重复
    /// 确认，而旧实现会把刚建立的请求立刻取消（NSURLError -999、空回答）。真正的停止
    /// 意图在武装期过后随时生效；武装期内被忽略的停止会留下调试日志。
    static let stopArmingInterval: TimeInterval = 1.0

    func stopGenerating() {
        guard streaming else { return }
        if let beganAt = streamingBeganAt, Date().timeIntervalSince(beganAt) < Self.stopArmingInterval {
            chatLog.debug("stop ignored: within arming window (\(String(format: "%.0f", Date().timeIntervalSince(beganAt) * 1000))ms)")
            return
        }
        stopRequested = true
        generationTask?.cancel()
    }

    func editAndResend(paperId: String, messageId: String, content: String) async {
        guard !busy, let session = currentSession,
              let turn = ChatRevision.editing(session, messageId: messageId, content: content) else { return }
        await sendRevision(paperId: paperId, source: session, turn: turn)
    }

    func regenerate(paperId: String, assistantId: String) async {
        guard !busy, let session = currentSession,
              let turn = ChatRevision.regenerating(session, assistantId: assistantId) else { return }
        await sendRevision(paperId: paperId, source: session, turn: turn)
    }

    private func sendRevision(paperId: String, source: ChatSession, turn: ChatRevision.Turn) async {
        let version = requestVersion
        preparingRevision = true
        defer { if version == requestVersion { preparingRevision = false } }
        var branch = ChatSession(id: PaperLibrary.newId(), paperId: paperId,
                                 title: String(source.title.prefix(42)) + " · 修订", messages: turn.history,
                                 createdAt: PaperLibrary.now())
        for index in branch.messages.indices { branch.messages[index].sessionId = branch.id }
        do {
            try await library.saveChatSession(paperId: paperId, session: branch)
            guard version == requestVersion else { return }
            currentSession = branch
            preparingRevision = false
            await sendMessage(paperId: paperId, content: turn.content, attachedContext: turn.context)
        } catch {
            guard version == requestVersion else { return }
            self.error = ApiFailure.wrap(error).localizedDescription
        }
    }

    func newSession() {
        guard !busy else { return }
        requestVersion = UUID()
        currentSession = nil
        streamContent = ""
        streamSources = []; agentActivity = ""; libraryPaperCount = 0; libraryQueryCount = 0
        pendingMessage = nil
    }
}
