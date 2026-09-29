import SwiftUI
import UniformTypeIdentifiers

/// Mirrors chat/ChatPanel.tsx — sessions, streaming bubbles, citation chips,
/// attached context, preset prompts, note synthesis and export.
struct ChatPanel: View {
    @Environment(\.palette) private var palette
    @Environment(\.apiClient) private var client
    @Environment(ChatStore.self) private var chatStore
    @Environment(ReaderStore.self) private var readerStore
    @Environment(SettingsStore.self) private var settingsStore

    let paperId: String

    @State private var input = ""
    @State private var noteMode = false
    @State private var selectedIds: [String] = []
    @State private var notes: [Note] = []
    @State private var busyNote = false
    @State private var copiedId: String?
    @State private var exportNote: Note?

    private var messages: [ChatMessage] { chatStore.currentSession?.messages ?? [] }
    private var prompts: [PresetPrompt] { settingsStore.settings?.chatDefaults.presetPrompts ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            sessionBar
            messagesList
            if !readerStore.attachedContext.isEmpty { attachedRow }
            if !prompts.isEmpty { promptRow }
            if noteMode { noteToolbar }
            composer
        }
        .background(palette.gray0)
        .task {
            if notes.isEmpty {
                notes = (try? await client.notesList(paperId: paperId)) ?? []
            }
        }
        .fileExporter(
            isPresented: .init(get: { exportNote != nil }, set: { if !$0 { exportNote = nil } }),
            document: exportNote.map { MarkdownFile(title: $0.title, content: $0.markdownContent) },
            contentType: .plainText,
            defaultFilename: (exportNote?.title.isEmpty == false ? exportNote?.title : "paper-note") ?? "paper-note"
        ) { _ in exportNote = nil }
    }

    struct MarkdownFile: FileDocument {
        static var readableContentTypes: [UTType] { [.plainText] }
        var title: String
        var content: String

        init(title: String, content: String) {
            self.title = title
            self.content = content
        }

        init(configuration: ReadConfiguration) throws {
            content = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
            title = "note"
        }

        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
            FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
        }
    }

    // MARK: session bar

    private var sessionBar: some View {
        HStack(spacing: 7) {
            Button {
                chatStore.newSession()
                selectedIds = []
            } label: {
                HStack(spacing: 5) {
                    Image.ic(Ic.plus).font(.system(size: 11))
                    Text("新对话")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.gray500)
                .padding(.horizontal, 9)
                .frame(minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.gray100))
            }
            .buttonStyle(.plain)

            if !chatStore.sessions.isEmpty {
                Picker("", selection: Binding(
                    get: { chatStore.currentSession?.id ?? "" },
                    set: { newValue in
                        guard !newValue.isEmpty else { return }
                        Task { await chatStore.loadSession(paperId: paperId, sessionId: newValue) }
                    }
                )) {
                    Text("历史对话").tag("")
                    ForEach(chatStore.sessions) { session in
                        Text(session.title.isEmpty ? "未命名对话" : session.title).tag(session.id)
                    }
                }
                .labelsHidden()
                .font(.system(size: 12))
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.gray0))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.gray200))
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    noteMode.toggle()
                    if !noteMode { selectedIds = [] }
                }
            } label: {
                Image.ic(Ic.penLine)
                    .font(.system(size: 13))
                    .foregroundStyle(noteMode ? .white : palette.gray500)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(noteMode ? palette.accent : palette.gray100))
            }
            .buttonStyle(.plain)
            .help("选择回答导出笔记")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 48)
    }

    // MARK: messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty && !chatStore.streaming {
                        emptyState
                    }
                    ForEach(messages) { message in
                        messageRow(message)
                    }
                    if chatStore.streaming {
                        streamingBubble
                    }
                    Color.clear.frame(height: 1).id("chat-end")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 13)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-end", anchor: .bottom) }
            }
            .onChange(of: chatStore.streamContent) { _, _ in
                proxy.scrollTo("chat-end", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(palette.gray50)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.gray200))
                    .frame(width: 48, height: 48)
                    .offset(x: -3, y: 3)
                Image.ic(Ic.bot)
                    .font(.system(size: 21))
                    .foregroundStyle(palette.accent)
                Image.ic(Ic.astroid)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.accent)
                    .offset(x: 12, y: -12)
            }
            .frame(width: 48, height: 48)
            Text("向论文提问")
                .font(.reading(16, weight: .medium))
                .foregroundStyle(palette.gray600)
            Text("支持追问、选中文本,回答可回溯原文。")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(palette.gray400)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.top, 30)
    }

    private func messageRow(_ message: ChatMessage) -> some View {
        let isUser = message.role == "user"
        return VStack(alignment: isUser ? .trailing : .leading, spacing: 0) {
            if noteMode {
                Button {
                    if selectedIds.contains(message.id) {
                        selectedIds.removeAll { $0 == message.id }
                    } else {
                        selectedIds.append(message.id)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image.ic(selectedIds.contains(message.id) ? Ic.checkSquare : Ic.square)
                            .font(.system(size: 12))
                        Text("选入笔记").font(.system(size: 9))
                    }
                    .foregroundStyle(selectedIds.contains(message.id) ? palette.accent : palette.gray400)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                .padding(.bottom, 2)
            }

            HStack(alignment: .bottom, spacing: 4) {
                if isUser { Spacer(minLength: 20) }

                VStack(alignment: .leading, spacing: 5) {
                    if let contexts = message.attachedContext, !contexts.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(Array(contexts.enumerated()), id: \.offset) { _, context in
                                Text(context.snippet?.prefix(36).description ?? context.type)
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.22)))
                            }
                        }
                    }

                    if isUser {
                        Text(message.content)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    } else {
                        MarkdownText(text: message.content, fontSize: 14, color: palette.gray700)
                    }

                    if let cited = message.citedBlockIds, !cited.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(cited, id: \.self) { blockId in
                                Button {
                                    readerStore.scrollToBlock(blockId, centered: true)
                                } label: {
                                    Text("证据 \(blockId.split(separator: "-").last.map(String.init) ?? blockId)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(palette.accent)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(RoundedRectangle(cornerRadius: 3).fill(palette.accentSoft))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .frame(maxWidth: 380, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(isUser ? palette.accent : palette.gray100)
                )
                .overlay(alignment: .topLeading) {
                    // bubble tail corner radius trick: emulate 11/11/11/3 radii
                    Color.clear
                }

                if !isUser {
                    VStack(alignment: .leading, spacing: 2) {
                        Button {
                            copyToClipboard(message.content)
                            copiedId = message.id
                            Task {
                                try? await Task.sleep(nanoseconds: 1_600_000_000)
                                if copiedId == message.id { copiedId = nil }
                            }
                        } label: {
                            Image.ic(copiedId == message.id ? Ic.check : Ic.copy)
                                .font(.system(size: 9))
                                .foregroundStyle(palette.gray400)
                                .padding(3)
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var streamingBubble: some View {
        HStack(alignment: .bottom, spacing: 4) {
            VStack(alignment: .leading, spacing: 5) {
                MarkdownText(text: chatStore.streamContent.isEmpty ? "正在思考…" : chatStore.streamContent, fontSize: 14, color: palette.gray700)
                SpinnerIcon(size: 11)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.gray100))
            Spacer(minLength: 20)
        }
    }

    // MARK: rows above composer

    private var attachedRow: some View {
        HStack(spacing: 5) {
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
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.accentSoft))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var promptRow: some View {
        HStack(spacing: 5) {
            ForEach(Array(prompts.prefix(4).enumerated()), id: \.offset) { _, prompt in
                Button {
                    input = prompt.template
                } label: {
                    Text(prompt.label)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.gray500)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.gray0))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.gray200))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(selectedIds.isEmpty || busyNote ? palette.accent.opacity(0.4) : palette.accent))
            }
            .buttonStyle(.plain)
            .disabled(selectedIds.isEmpty || busyNote)

            if let recent = notes.first {
                Button {
                    exportNote = recent
                } label: {
                    Text("下载最近笔记")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.gray500)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.gray0))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.gray200))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("针对这篇论文提问…", text: $input, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(size: 14))
                .padding(8)
                .onSubmit { sendMessage() }
                .disabled(chatStore.streaming)

            Button {
                sendMessage()
            } label: {
                Image.ic(Ic.send)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 11).fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatStore.streaming ? palette.accent.opacity(0.35) : palette.accent))
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatStore.streaming)
            .help("发送")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.gray50))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.gray200))
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: actions

    private func sendMessage() {
        let content = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !chatStore.streaming else { return }
        input = ""
        let contexts = readerStore.attachedContext.isEmpty ? nil : readerStore.attachedContext
        Task {
            await chatStore.sendMessage(paperId: paperId, content: content, attachedContext: contexts)
            readerStore.clearAttachedContext()
        }
    }

    private func synthesizeNote() async {
        guard !selectedIds.isEmpty else { return }
        busyNote = true
        defer { busyNote = false }
        do {
            let note = try await client.notesSynthesize(paperId: paperId, title: "", messageIds: selectedIds)
            notes.insert(note, at: 0)
            selectedIds = []
            noteMode = false
        } catch {
            // Errors surface through the session UI; keep the selection intact.
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
