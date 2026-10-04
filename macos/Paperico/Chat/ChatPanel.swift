import SwiftUI

/// Mirrors chat/ChatPanel.tsx — sessions, streaming bubbles, citation chips,
/// attached context, preset prompts, note synthesis and export.
struct ChatPanel: View {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppServices.self) private var services
    @Environment(ChatStore.self) private var chatStore
    @Environment(ReaderStore.self) private var readerStore
    @Environment(SettingsStore.self) private var settingsStore

    let paperId: String

    @State private var input = ""
    @State private var composerFocused = false
    @State private var inputHeight: CGFloat = 32
    @State private var editingMessageId: String?
    @State private var draftBeforeEditing = ""
    @State private var followsLatest = true
    @State private var noteMode = false
    @State private var selectedIds: [String] = []
    @State private var notes: [Note] = []
    @State private var busyNote = false
    @State private var copiedId: String?
    @State private var isExportingNote = false
    @State private var hoveredPrompt: Int?
    @State private var historyExpanded = false
    @State private var renamingSessionId: String?
    @State private var sessionTitle = ""
    @State private var sessionToDelete: ChatSession?
    @FocusState private var historyFocused: Bool

    private var messages: [ChatMessage] {
        var result = chatStore.currentSession?.messages ?? []
        if let pending = chatStore.pendingMessage { result.append(pending) }
        return result
    }
    private var prompts: [PresetPrompt] { settingsStore.settings?.chatDefaults.presetPrompts ?? [] }
    private var citationIds: Set<String> { Set(readerStore.paper?.blocks.map(\.id) ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            sessionBar
            messagesList
            if !readerStore.attachedContext.isEmpty { attachedRow }
            if !prompts.isEmpty { promptRow }
            if noteMode { noteToolbar }
            composer
        }
        .background(Color.clear)
        .overlay(alignment: .topLeading) {
            if historyExpanded {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle()).onTapGesture { closeHistory() }
                        historyPanel
                            .frame(height: min(280, max(90, geometry.size.height - 12), CGFloat(chatStore.sessions.count) * 48 + 16))
                            .padding(.horizontal, 12)
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }.padding(.top, 44)
            }
        }
        .onExitCommand {
            if historyExpanded { closeHistory() }
            else if chatStore.streaming { chatStore.stopGenerating() }
        }
        .onChange(of: paperId) { _, _ in historyExpanded = false; renamingSessionId = nil; sessionToDelete = nil }
        .task {
            if notes.isEmpty {
                do { notes = try await services.library.notes(paperId: paperId) }
                catch { chatStore.error = ApiFailure.wrap(error).errorDescription ?? "笔记读取失败" }
            }
        }
        .alert("对话与笔记", isPresented: .init(get: { !chatStore.error.isEmpty }, set: { if !$0 { chatStore.error = "" } })) {
            Button("好") { chatStore.error = "" }
        } message: { Text(chatStore.error) }
        .alert("删除对话？", isPresented: .init(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } })) {
            Button("取消", role: .cancel) { sessionToDelete = nil }
            Button("删除", role: .destructive) {
                guard let session = sessionToDelete else { return }
                sessionToDelete = nil
                let wasCurrent = session.id == chatStore.currentSession?.id
                Task {
                    await chatStore.deleteSession(paperId: paperId, sessionId: session.id)
                    if renamingSessionId == session.id { renamingSessionId = nil }
                    if wasCurrent && chatStore.currentSession == nil {
                        selectedIds = []
                        if editingMessageId != nil { cancelEditing() }
                    }
                }
            }
        } message: {
            Text("将永久删除“\(sessionToDelete?.title ?? "")”及其全部消息。已导出的笔记会保留。")
        }
    }

    // MARK: session bar

    private var sessionBar: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { historyExpanded.toggle() }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium)).frame(width: 32, height: 32)
                    .liquidTool(tint: historyExpanded ? palette.accentSoft : nil)
            }
            .disabled(chatStore.busy || chatStore.sessions.isEmpty)
            .help("历史对话").accessibilityLabel("历史对话")
            .accessibilityValue(historyExpanded ? "已展开" : "已收起")

            Button {
                closeHistory()
                chatStore.newSession()
                selectedIds = []
                if editingMessageId != nil { cancelEditing() }
            } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32).liquidTool()
            }.disabled(chatStore.busy).help("新对话").accessibilityLabel("新对话")

            Text(historyTitle(chatStore.currentSession?.title ?? "新对话", limit: 40))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.gray700)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .help(chatStore.currentSession?.title ?? "新对话")
                .accessibilityLabel("当前对话：" + (chatStore.currentSession?.title ?? "新对话"))

            Button {
                closeHistory()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    noteMode.toggle()
                    if !noteMode { selectedIds = [] }
                }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(noteMode ? palette.accent : palette.gray500)
                    .frame(width: 32, height: 32)
                    .liquidTool(tint: noteMode ? palette.accentSoft : nil)
            }.help("选择回答导出笔记").accessibilityLabel("导出笔记")
                .frame(width: 71, alignment: .trailing)
        }
        .foregroundStyle(palette.gray500).buttonStyle(.plain).noFocusRing()
        .padding(.horizontal, 12).padding(.vertical, 6).frame(height: 44)
    }

    private var historyPanel: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(chatStore.sessions) { session in
                    if renamingSessionId == session.id {
                        InlineNameEditor(name: $sessionTitle, prompt: "对话名称", fontSize: 12, busy: chatStore.updatingSession) {
                            Task {
                                if await chatStore.renameSession(paperId: paperId, sessionId: session.id, title: sessionTitle) {
                                    renamingSessionId = nil
                                }
                            }
                        } onCancel: { renamingSessionId = nil }
                        .padding(.horizontal, 10).frame(minHeight: 45)
                    } else {
                        Button {
                        closeHistory()
                        selectedIds = []
                        if editingMessageId != nil { cancelEditing() }
                        Task { await chatStore.loadSession(paperId: paperId, sessionId: session.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Text(historyTitle(session.title, limit: 60))
                                .font(.system(size: 12)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if session.id == chatStore.currentSession?.id {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                            }
                        }
                        .foregroundStyle(palette.gray800).padding(.horizontal, 10).frame(height: 45)
                        .background(session.id == chatStore.currentSession?.id ? palette.accentFaint : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                        }.buttonStyle(.plain).noFocusRing().disabled(chatStore.busy)
                        .contextMenu {
                            Button("改名", systemImage: "pencil") {
                                sessionTitle = session.title
                                renamingSessionId = session.id
                            }.disabled(chatStore.busy)
                            Button("删除", systemImage: "trash", role: .destructive) { sessionToDelete = session }
                                .disabled(chatStore.busy)
                        }
                    }
                }
            }.padding(8)
        }
        .scrollIndicators(.hidden)
        .liquidPanel(cornerRadius: 16).environment(\.floatingSurface, true)
        .focusable().focusEffectDisabled().focused($historyFocused)
        .onAppear { historyFocused = true }
        .onDisappear { historyFocused = false }
        .onExitCommand { closeHistory() }
        .accessibilityLabel("历史对话列表")
    }

    private func closeHistory() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { historyExpanded = false }
        renamingSessionId = nil
    }

    // MARK: messages

    private var messagesList: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if messages.isEmpty && !chatStore.streaming {
                            emptyState.frame(minHeight: max(100, geometry.size.height - 28))
                        }
                        ForEach(messages) { message in
                            messageRow(message)
                        }
                        if chatStore.streaming { streamingBubble }
                        Color.clear.frame(height: 1).id("chat-end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
                } action: { _, nearBottom in followsLatest = nearBottom }
                .overlay(alignment: .bottomTrailing) {
                    if !followsLatest && !messages.isEmpty {
                        Button {
                            followsLatest = true
                            withAnimation { proxy.scrollTo("chat-end", anchor: .bottom) }
                        } label: { Image(systemName: "arrow.down").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).liquidTool().padding(8).help("回到最新回答")
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
                .onChange(of: chatStore.streamContent) { _, _ in
                    if followsLatest { proxy.scrollTo("chat-end", anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 24, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette.accent)
            Text("向论文提问")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.gray800)
            Text("选中原文追问，或从下方开始。\n回答中的证据可带你回到论文。")
                .font(.system(size: 11.5))
                .lineSpacing(4)
                .foregroundStyle(palette.gray500)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let isUser = message.role == "user"
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            if noteMode {
                Button {
                    if selectedIds.contains(message.id) { selectedIds.removeAll { $0 == message.id } }
                    else { selectedIds.append(message.id) }
                } label: {
                    Label("选入笔记", systemImage: selectedIds.contains(message.id) ? Ic.checkSquare : Ic.square)
                        .font(.system(size: 11))
                        .foregroundStyle(selectedIds.contains(message.id) ? palette.accent : palette.gray500)
                }
                .buttonStyle(.plain)
            }
            if isUser {
                HStack {
                    Spacer(minLength: 24)
                    VStack(alignment: .leading, spacing: 8) {
                        if let contexts = message.attachedContext, !contexts.isEmpty {
                            FlowChips {
                                ForEach(Array(contexts.enumerated()), id: \.offset) { _, context in
                                    Label(context.snippet?.prefix(36).description ?? context.type, systemImage: "text.quote")
                                        .font(.system(size: 10)).lineLimit(2)
                                        .foregroundStyle(palette.gray600)
                                }
                            }
                        }
                        Text(message.content)
                            .foregroundStyle(palette.gray900)
                            .font(.system(size: 13)).lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .liquidInset(cornerRadius: 16, tint: palette.accentSoft)
                }
                messageActions(message, isUser: true)
            } else {
                MarkdownText(text: message.content, fontSize: 13, color: palette.gray800,
                             citationIds: citationIds, onCitation: { readerStore.scrollToBlock($0, centered: true) })
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                if let state = message.generationState {
                    Text(state == "stopped" ? "已停止生成" : "回答中断，可重新生成")
                        .font(.system(size: 10)).foregroundStyle(palette.gray500)
                }
                messageActions(message, isUser: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func messageActions(_ message: ChatMessage, isUser: Bool) -> some View {
        HStack(spacing: 4) {
            if isUser { Spacer(minLength: 0) }
            Button {
                copyToClipboard(message.content); copiedId = message.id
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    if copiedId == message.id { copiedId = nil }
                }
            } label: {
                Image.ic(copiedId == message.id ? Ic.check : Ic.copy).frame(width: 25, height: 25)
            }.help(copiedId == message.id ? "已复制" : "复制消息").accessibilityLabel("复制消息")
            if isUser {
                Button { beginEditing(message) } label: { Image(systemName: "pencil").frame(width: 25, height: 25) }
                    .disabled(chatStore.busy).help("编辑并重新发送").accessibilityLabel("编辑提问")
            } else {
                Button { Task { await chatStore.regenerate(paperId: paperId, assistantId: message.id) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 25, height: 25)
                }.disabled(chatStore.busy).help("重新生成，保留原对话").accessibilityLabel("重新生成回答")
                if message.generationState == "stopped" {
                    Button {
                        input = "请继续上一条尚未完成的回答，从停止的位置接着写。"
                        composerFocused = true
                    } label: { Image(systemName: "play").frame(width: 25, height: 25) }
                    .help("继续回答").accessibilityLabel("继续回答")
                }
                Spacer(minLength: 0)
            }
        }.font(.system(size: 11)).foregroundStyle(palette.gray500).buttonStyle(.plain)
    }

    private var streamingBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            if chatStore.streamContent.isEmpty {
                HStack(spacing: 7) {
                    SpinnerIcon(size: 11)
                    Text("正在思考…").font(.system(size: 12)).foregroundStyle(palette.gray500)
                }
            } else {
                MarkdownText(text: chatStore.streamContent, fontSize: 13, color: palette.gray800,
                             citationIds: citationIds, onCitation: { readerStore.scrollToBlock($0, centered: true) })
                    .lineSpacing(4)
                SpinnerIcon(size: 11)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: rows above composer

    private var attachedRow: some View {
        FlowChips {
            ForEach(Array(readerStore.attachedContext.enumerated()), id: \.offset) { index, context in
                HStack(spacing: 3) {
                    Image.ic(context.type == "text_selection" ? Ic.fileText : (context.type == "figure" ? Ic.image : Ic.tag))
                        .font(.system(size: 9))
                    Text(context.snippet?.prefix(28).description ?? context.type)
                        .lineLimit(1)
                    Button {
                        readerStore.removeAttachedContext(at: index)
                    } label: {
                        Image.ic(Ic.close).font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 9))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous).fill(palette.accentSoft))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var promptRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(prompts.prefix(4).enumerated()), id: \.offset) { index, prompt in
                Button {
                    input = prompt.template
                    composerFocused = true
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: promptIcon(index)).font(.system(size: 14))
                            .frame(width: 34, height: 34)
                        if hoveredPrompt == index {
                            Text(prompt.label).font(.system(size: 11)).lineLimit(1)
                                .padding(.trailing, 12)
                                .transition(.opacity)
                        }
                    }
                    .foregroundStyle(hoveredPrompt == index ? palette.accent : palette.gray600)
                    .frame(height: 34)
                    .liquidTool(tint: hoveredPrompt == index ? palette.accentFaint : nil)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                        if hovering { hoveredPrompt = index }
                        else if hoveredPrompt == index { hoveredPrompt = nil }
                    }
                }
                .help(prompt.label).accessibilityLabel(prompt.label)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func promptIcon(_ index: Int) -> String {
        switch index {
        case 0: return "doc.text"
        case 1: return "list.bullet.rectangle"
        case 2: return "sparkles"
        default: return "binoculars"
        }
    }

    private var noteToolbar: some View {
        HStack(spacing: 8) {
            Text("已选 \(selectedIds.count) 条").font(.system(size: 11)).foregroundStyle(palette.gray500)
            Button {
                Task { await synthesizeNote() }
            } label: {
                HStack(spacing: 4) {
                    if busyNote { SpinnerIcon(size: 10) }
                    Text("生成笔记")
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.accentForeground)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous).fill(selectedIds.isEmpty || busyNote ? palette.accent.opacity(0.4) : palette.accent))
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty || busyNote)

            if let recent = notes.first {
                Button {
                    chatStore.error = ""
                    isExportingNote = true
                    Task {
                        defer { isExportingNote = false }
                        do { try await MarkdownExporter.export(recent) }
                        catch { chatStore.error = "笔记导出失败：\(ApiFailure.wrap(error).localizedDescription)" }
                    }
                } label: {
                    Text("下载最近笔记")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.gray500)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .liquidInset(cornerRadius: CornerRadius.chip)
                }
                .buttonStyle(.plain)
                .disabled(isExportingNote)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if editingMessageId != nil {
                HStack(spacing: 6) {
                    Image(systemName: "pencil").font(.system(size: 10))
                    Text("编辑提问，原对话会保留").font(.system(size: 10))
                    Spacer()
                    Button(action: cancelEditing) { Image(systemName: "xmark").frame(width: 20, height: 20) }
                        .buttonStyle(.plain).help("取消编辑")
                }.foregroundStyle(palette.accent)
            }
            HStack(alignment: .center, spacing: 8) {
                MessageInput(text: $input, height: $inputHeight, focused: $composerFocused,
                             placeholder: "向论文提问…", onSubmit: sendMessage,
                             onCancel: {
                                 if editingMessageId != nil { cancelEditing() }
                                 else if chatStore.streaming { chatStore.stopGenerating() }
                             }, onRecall: {
                                 if let message = messages.last(where: { $0.role == "user" }) { beginEditing(message) }
                             }, fontSize: editingMessageId == nil ? 12.5 : 13)
                    .frame(height: inputHeight).frame(maxWidth: .infinity)
                    .accessibilityLabel("针对这篇论文提问")
                Button {
                    if chatStore.streaming { chatStore.stopGenerating() }
                    else { sendMessage() }
                } label: {
                    Image(systemName: chatStore.streaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: chatStore.streaming ? 11 : 15, weight: .semibold))
                        .foregroundStyle(canSend || chatStore.streaming ? palette.accentForeground : palette.gray500)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend || chatStore.streaming ? palette.accent : palette.insetSurface))
                }.buttonStyle(.plain).disabled(!canSend && !chatStore.streaming)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(chatStore.streaming ? "停止生成（Esc）" : "发送（Enter 或 ⌘↩），Shift+Enter 换行")
                    .accessibilityLabel(chatStore.streaming ? "停止生成" : "发送")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .liquidInset(cornerRadius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(composerFocused ? palette.accent.opacity(0.45) : Color.clear))
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
    }

    private var canSend: Bool { !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatStore.busy }
    private func historyTitle(_ title: String, limit: Int) -> String {
        let value = title.isEmpty ? "未命名对话" : title.replacingOccurrences(of: "\n", with: " ")
        return value.count > limit ? String(value.prefix(limit)) + "…" : value
    }

    // MARK: actions

    private func beginEditing(_ message: ChatMessage) {
        guard !chatStore.busy else { return }
        if editingMessageId == nil { draftBeforeEditing = input }
        editingMessageId = message.id; input = message.content; composerFocused = true
    }
    private func cancelEditing() { editingMessageId = nil; input = draftBeforeEditing; composerFocused = true }
    private func sendMessage() {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !chatStore.busy else { return }
        let editing = editingMessageId
        input = ""; editingMessageId = nil; followsLatest = true
        let contexts = readerStore.attachedContext.isEmpty ? nil : readerStore.attachedContext
        readerStore.clearAttachedContext()
        Task {
            if let editing { await chatStore.editAndResend(paperId: paperId, messageId: editing, content: content) }
            else { await chatStore.sendMessage(paperId: paperId, content: content, attachedContext: contexts) }
        }
    }

    private func synthesizeNote() async {
        guard !selectedIds.isEmpty else { return }
        busyNote = true
        defer { busyNote = false }
        do {
            let note = try await ChatService.synthesizeNote(
                paperId: paperId, title: "", messageIds: selectedIds,
                library: services.library, llm: settingsStore.llmConfig(for: .notes)
            )
            notes.insert(note, at: 0)
            selectedIds = []
            noteMode = true
        } catch {
            chatStore.error = "笔记生成失败：\(ApiFailure.wrap(error).localizedDescription)"
        }
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
