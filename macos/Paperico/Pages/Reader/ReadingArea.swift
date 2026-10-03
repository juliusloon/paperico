import SwiftUI

enum ReaderViewMode: String {
    case text, pdf
}

/// Mirrors reader/ReadingArea.tsx — floating tools, margin-outline document,
/// processing/error stages, progress tracking, block flash highlighting.
struct ReadingArea: View {
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(ReaderStore.self) private var readerStore
    @Environment(AppServices.self) private var services

    var toolsObscured = false
    @Binding var leftWidth: CGFloat

    @State private var viewModeOverride: ReaderViewMode?
    @State private var pdfVisited = false
    @State private var textProgress: Double = 0
    @State private var pdfProgress: Double = 0
    @State private var pdfZoom: Double = 1
    @State private var retranslateBusy = false
    @State private var retranslateRequestedFor = ""
    @State private var retranslateError = ""
    @State private var confirmRetranslate = false
    @State private var retranslateStartedAt: Date?
    @State private var retranslateCompleted = false

    private var paper: PaperListItem? { readerStore.paper?.paper }
    private var blocks: [Block] { readerStore.paper?.blocks ?? [] }
    private var paperId: String { paper?.id ?? "" }

    private var viewMode: ReaderViewMode {
        if let override = viewModeOverride { return override }
        if !paperId.isEmpty { return LocalPrefs.readerMode(paperId: paperId) == "pdf" ? .pdf : .text }
        return .text
    }

    private var isCompact: Bool { containerWidth < LayoutBreakpoint.reader }
    private var outlineVisible: Bool { !isCompact && !readerStore.leftPanelCollapsed }
    private var outlineWidth: CGFloat { outlineVisible ? leftWidth : 0 }
    private var paperProcessing: Bool {
        guard let status = paper?.statusEnum else { return false }
        return status.isActive || services.pipeline.isProcessing(paperId)
    }
    private var activeProgress: Double { viewMode == .pdf ? pdfProgress : textProgress }

    private var retranslateActive: Bool {
        retranslateBusy || (retranslateRequestedFor == paperId && paperProcessing && !retranslateRequestedFor.isEmpty)
    }

    private var backgroundRetranslateError: String? {
        guard retranslateRequestedFor == paperId,
              !services.pipeline.isProcessing(paperId),
              paper?.statusEnum == .error,
              let message = paper?.errorMessage, !message.isEmpty else { return nil }
        return "重新翻译失败：\(message)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            if viewMode == .text {
                textReadingScroll
                    .opacity(viewMode == .text ? 1 : 0)
            }
            if pdfVisited, !paperId.isEmpty {
                PdfReadingArea(
                    paperId: paperId,
                    layout: services.library.layout,
                    zoom: $pdfZoom,
                    progress: $pdfProgress,
                    onAttachSelection: { snippet in
                        readerStore.addAttachedContext(AttachedContext(
                            type: "text_selection", refBlockId: nil, refEntityId: nil, snippet: snippet
                        ))
                    }
                )
                .opacity(viewMode == .pdf ? 1 : 0)
                .allowsHitTesting(viewMode == .pdf)
            }

            VStack(alignment: .trailing, spacing: 8) {
                floatingTools
                    .opacity(toolsObscured ? 0 : 1)
                    .allowsHitTesting(!toolsObscured)
                    .accessibilityHidden(toolsObscured)
                if retranslateActive {
                    retranslationProgress.transition(.opacity)
                }
                if retranslateCompleted {
                    retryBanner(icon: Ic.check, spinner: false, text: "重新翻译完成，正文与论文简介已更新。", color: palette.success)
                }
                if let error = visibleRetranslateError {
                    retryBanner(icon: Ic.alertTriangle, spinner: false, text: error, color: palette.danger)
                        .transition(.opacity)
                }
            }
            .padding(.top, 14)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(2)
            .allowsHitTesting(true)

            GeometryReader { geo in
                Rectangle()
                    .fill(palette.accent)
                    .frame(width: geo.size.width * activeProgress / 100, height: 2)
            }
            .frame(height: 2)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .animation(.easeInOut(duration: 0.18), value: activeProgress)
        }
        .background(Color.clear)
        .animation(.easeInOut(duration: 0.18), value: retranslateActive)
        .animation(.easeInOut(duration: 0.18), value: visibleRetranslateError == nil)
        .alert("重新翻译这篇论文？", isPresented: $confirmRetranslate) {
            Button("取消", role: .cancel) {}
            Button("重新翻译") { Task { await handleRetranslate() } }
        } message: {
            Text("将重新生成全文译文、逻辑链和论文简介，并调用已配置的模型。成功后替换现有结果；对话和笔记会保留。")
        }
        .onChange(of: services.pipeline.isProcessing(paperId)) { wasProcessing, processing in
            guard wasProcessing, !processing, retranslateRequestedFor == paperId else { return }
            Task {
                await readerStore.refreshPaper(id: paperId)
                retranslateCompleted = paper?.statusEnum == .ready
                if let failure = services.pipeline.failures[paperId] { retranslateError = failure }
                if retranslateCompleted {
                    try? await Task.sleep(for: .seconds(6))
                    retranslateCompleted = false
                }
            }
        }
        .onAppear { hydrateLocalState() }
        .onChange(of: paperId) { _, _ in hydrateLocalState() }
    }

    private var visibleRetranslateError: String? {
        retranslateError.isEmpty ? backgroundRetranslateError : retranslateError
    }

    private func hydrateLocalState() {
        guard !paperId.isEmpty else { return }
        if viewModeOverride == nil {
            let stored: ReaderViewMode = LocalPrefs.readerMode(paperId: paperId) == "pdf" ? .pdf : .text
            viewModeOverride = stored
            pdfVisited = stored == .pdf
        }
        // Chat chips / MetaCard / outline jumps branch on the active surface (T2.3).
        readerStore.setViewMode(viewMode)
        textProgress = LocalPrefs.textProgress(paperId: paperId)
        pdfProgress = LocalPrefs.pdfProgress(paperId: paperId)
        pdfZoom = LocalPrefs.pdfZoom(paperId: paperId)
        if retranslateRequestedFor != paperId {
            retranslateError = ""
        }
    }

    // MARK: floating tools

    private var floatingTools: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                toolButton(icon: viewMode == .text ? Ic.fileText : Ic.fileType,
                           help: viewMode == .text ? "查看原始 PDF" : "返回文本精读") { toggleViewMode() }
                toolButton(icon: readerStore.bilingualMode == .original ? Ic.pilcrow : Ic.languages,
                           help: viewMode == .pdf ? "PDF 模式不提供译文切换" : "切换原文与双语") {
                    readerStore.setBilingualMode(readerStore.bilingualMode == .original ? .bilingual : .original)
                }.disabled(viewMode == .pdf)
                Button { confirmRetranslate = true } label: {
                    Group {
                        if retranslateActive { SpinnerIcon(size: 16) }
                        else { Image.ic(Ic.refresh).font(.system(size: 16, weight: .medium)) }
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain).noFocusRing()
                .liquidTool(cornerRadius: 20)
                .disabled(paper == nil || blocks.isEmpty || paperProcessing || retranslateBusy)
                .help("重新翻译").accessibilityLabel("重新翻译")
                HStack(spacing: 7) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                        Circle().trim(from: 0, to: activeProgress / 100)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }.frame(width: 15, height: 15)
                    Text(viewMode == .pdf ? String(format: "%.1f%%", activeProgress) : "\(Int(activeProgress.rounded()))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .frame(width: 84, height: 40).liquidTool(cornerRadius: 20)
                .help("阅读进度")
                HStack(spacing: 0) {
                    scaleButton(icon: "minus", help: "缩小") { changeReadingScale(-1) }
                    Text(viewMode == .pdf ? "\(Int((pdfZoom * 100).rounded()))%" : "\(Int(readerStore.fontSize))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary).frame(width: 48)
                    scaleButton(icon: "plus", help: "放大") { changeReadingScale(1) }
                }.frame(width: 112, height: 40).liquidTool(cornerRadius: 20)
            }
        }
    }

    private func scaleButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary).frame(width: 32, height: 36).contentShape(Circle())
        }.buttonStyle(.plain).noFocusRing().help(help).accessibilityLabel(help)
    }

    private func toolButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.ic(icon).font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary).frame(width: 40, height: 40)
        }
        .buttonStyle(.plain).noFocusRing()
        .liquidTool(cornerRadius: 20)
        .help(help).accessibilityLabel(help)
    }

    private func retryBanner(icon: String?, spinner: Bool, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if spinner {
                SpinnerIcon(size: 14)
            } else if let icon {
                Image.ic(icon).font(.system(size: 14)).foregroundStyle(color)
            }
            Text(text)
                .font(.system(size: 11))
                .lineSpacing(3)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: 420, alignment: .leading)
        .liquidPanel()
    }

    private var retranslationProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(services.pipeline.progress[paperId] ?? "正在准备重新翻译…")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.gray700)
                Spacer(minLength: 8)
                if let startedAt = retranslateStartedAt {
                    Text(startedAt, style: .timer).font(.system(size: 11))
                        .foregroundStyle(palette.gray500)
                }
            }
            if let progress = services.pipeline.nodeProgress[paperId], progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(progress.total))
                    .progressViewStyle(.linear).tint(palette.accent)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(14).frame(maxWidth: 420, alignment: .leading).liquidPanel()
    }

    // MARK: actions

    private func toggleViewMode() {
        let next: ReaderViewMode = viewMode == .text ? .pdf : .text
        viewModeOverride = next
        if next == .pdf { pdfVisited = true }
        readerStore.setViewMode(next)
        if !paperId.isEmpty { LocalPrefs.setReaderMode(next.rawValue, paperId: paperId) }
    }

    private func changeReadingScale(_ direction: Int) {
        if viewMode == .pdf {
            let next = pdfZoom + Double(direction) * 0.1
            let clamped = min(2.4, max(0.6, (next * 100).rounded() / 100))
            pdfZoom = clamped
            if !paperId.isEmpty { LocalPrefs.setPdfZoom(clamped, paperId: paperId) }
        } else {
            readerStore.setFontSize(readerStore.fontSize + CGFloat(direction))
        }
    }

    private func handleRetranslate() async {
        guard let paper, !blocks.isEmpty, !retranslateBusy, !paperProcessing else { return }
        retranslateBusy = true
        retranslateError = ""
        retranslateCompleted = false
        retranslateStartedAt = Date()
        retranslateRequestedFor = paper.id
        defer { retranslateBusy = false }
        // 本地管线直接启动重译任务;失败会在论文状态上落 error,由轮询呈现。
        services.pipeline.retranslate(paperId: paper.id)
        await readerStore.refreshPaper(id: paper.id)
    }

    private func handleReparse() async {
        guard let paper else { return }
        services.pipeline.reparse(paperId: paper.id)
        await readerStore.refreshPaper(id: paper.id)
    }

    // MARK: text reading scroll

    @ViewBuilder
    private var textReadingScroll: some View {
        if let detail = readerStore.paper, !detail.blocks.isEmpty {
            PaperDocumentView(
                detail: detail, annotations: readerStore.nodeAnnotations,
                onAnnotation: { id, field, value, phase in
                    if phase == "cancel" { readerStore.cancelPendingAnnotation() }
                    else {
                        readerStore.stageAnnotation(blockId: id, field: field, text: value)
                        if phase == "commit" { readerStore.commitPendingAnnotation() }
                    }
                }, onAnnotationFocus: { readerStore.editingAnnotation = $0 }, layout: services.library.layout,
                fontSize: readerStore.fontSize, mode: readerStore.bilingualMode,
                outlineWidth: outlineWidth, progress: textProgress,
                pendingTarget: readerStore.pendingScrollTarget,
                centered: readerStore.pendingScrollAnchorCentered,
                onProgress: { progress, blockId in
                    if abs(textProgress - progress) >= 0.03 { textProgress = progress }
                    if !blockId.isEmpty, readerStore.activeBlockId != blockId { readerStore.setActiveBlock(blockId) }
                    if abs(lastPersistedProgress - progress) >= 0.05 {
                        lastPersistedProgress = progress
                        persistTextProgress(progress)
                    }
                },
                onAttach: { readerStore.addAttachedContext($0) },
                onJump: { id in
                    if readerStore.pendingScrollTarget == id { readerStore.consumeScrollTarget() }
                    readerStore.setActiveBlock(id)
                }
            )
            .overlay(alignment: .leading) {
                if outlineVisible { outlineResizeHandle.offset(x: leftWidth - 4) }
            }
        } else if let paper, paper.statusEnum == .error {
            ScrollView { errorStage(paper: paper) }
        } else if let paper {
            processingStage(paper: paper)
        }
    }

    private func persistTextProgress(_ value: Double) {
        let id = paperId
        guard !id.isEmpty else { return }
        progressPersistItem?.cancel()
        let item = DispatchWorkItem { LocalPrefs.setTextProgress(value, paperId: id) }
        progressPersistItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    private var outlineResizeHandle: some View {
        ReaderDivider(axis: .horizontal, label: "调整逻辑链宽度") { translation in
            if dragStartWidth == nil { dragStartWidth = leftWidth }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                leftWidth = min(390, max(190, (dragStartWidth ?? leftWidth) + translation))
            }
        } onEnd: {
            dragStartWidth = nil
            LocalPrefs.leftWidth = leftWidth
        }
        .frame(width: 9)
    }

    @State private var dragStartWidth: CGFloat?
    @State private var lastPersistedProgress: Double = -1
    @State private var progressPersistItem: DispatchWorkItem?

    // MARK: stages

    private func processingStage(paper: PaperListItem) -> some View {
        VStack(spacing: 8) {
            Circle()
                .fill(palette.accentSoft)
                .frame(width: 54, height: 54)
                .overlay(ProgressView().controlSize(.regular).tint(palette.accent))
            Text("PREPARING PAPER")
                .font(.system(size: 10, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(palette.accent)
            Text(paper.statusEnum.processingCopy ?? "正在准备论文内容")
                .font(.reading(24, weight: .medium))
                .foregroundStyle(palette.gray900)
            Text("可以留在此页，完成后正文和逻辑目录会自动出现。")
                .font(.system(size: 11))
                .foregroundStyle(palette.gray500)
            stageRail(status: paper.statusEnum)
        }
        .frame(maxWidth: 520, minHeight: 520)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func stageRail(status: PaperStatus) -> some View {
        HStack {
            railDot(done: true)
            railDot(done: status != .uploaded)
            railDot(done: false)
            railDot(done: false)
        }
        .padding(.horizontal, 4)
        .overlay(alignment: .center) {
            Rectangle()
                .stroke(palette.gray300, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(height: 1)
                .padding(.horizontal, 12)
        }
        .frame(width: 210)
        .padding(.top, 30)
    }

    private func railDot(done: Bool) -> some View {
        Circle()
            .fill(done ? palette.accent : palette.gray300)
            .frame(width: 9, height: 9)
            .background(Circle().fill(done ? palette.accentSoft : Color.clear).frame(width: 17, height: 17))
    }

    private func errorStage(paper: PaperListItem) -> some View {
        VStack(spacing: 8) {
            Image.ic(Ic.alertTriangle)
                .font(.system(size: 22))
                .foregroundStyle(palette.accent)
                .frame(width: 54, height: 54)
                .background(Circle().fill(palette.accentSoft))
            Text("PROCESSING STOPPED")
                .font(.system(size: 10, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(palette.accent)
            Text("论文处理没有完成")
                .font(.reading(24, weight: .medium))
                .foregroundStyle(palette.gray900)
            Text(paper.originalFileName)
                .font(.system(size: 11))
                .foregroundStyle(palette.gray500)
            if let errorCode = paper.errorCode, !errorCode.isEmpty {
                // Mirrors web .error-code-chip (T0.1): programmable failure reason.
                Text(errorCode)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(palette.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous).fill(palette.danger.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: CornerRadius.chip, style: .continuous).stroke(palette.danger.opacity(0.3)))
            }
            Text(paper.errorMessage.isEmpty ? "请检查 API 配置后重新解析。" : paper.errorMessage)
                .font(.system(size: 9))
                .foregroundStyle(palette.danger)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).fill(palette.danger.opacity(0.08)))
                .fixedSize(horizontal: false, vertical: true)
            PrimaryActionButton(title: "重新解析", systemImage: Ic.rotateCcw) {
                Task { await handleReparse() }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: 520, minHeight: 520)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
