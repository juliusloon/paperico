import SwiftUI

enum ReaderViewMode: String {
    case text, pdf
}

/// Mirrors reader/ReadingArea.tsx — floating tools, margin-outline document,
/// processing/error stages, progress tracking, block flash highlighting.
struct ReadingArea: View {
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(ReaderStore.self) private var readerStore
    @Environment(\.apiClient) private var client
    @Environment(Router.self) private var router

    var mobile: Bool = false
    var initialView: String? = nil
    @Binding var leftWidth: CGFloat

    @State private var viewModeOverride: ReaderViewMode?
    @State private var pdfVisited = false
    @State private var textProgress: Double = 0
    @State private var pdfProgress: Double = 0
    @State private var pdfZoom: Double = 1
    @State private var retranslateBusy = false
    @State private var retranslateRequestedFor = ""
    @State private var retranslateError = ""
    @State private var restoredForPaper = ""
    @State private var blockFrames: [BlockFrame] = []
    @State private var viewportHeight: CGFloat = 1
    @State private var contentFrame: CGRect = .zero

    private var paper: PaperListItem? { readerStore.paper?.paper }
    private var blocks: [Block] { readerStore.paper?.blocks ?? [] }
    private var paperId: String { paper?.id ?? "" }

    private var viewMode: ReaderViewMode {
        if let override = viewModeOverride { return override }
        if let initialView, initialView == "pdf" { return .pdf }
        if !paperId.isEmpty { return LocalPrefs.readerMode(paperId: paperId) == "pdf" ? .pdf : .text }
        return .text
    }

    private var outlineVisible: Bool { mobile || !readerStore.leftPanelCollapsed }
    private var outlineWidth: CGFloat { outlineVisible ? leftWidth : 0 }
    private var paperProcessing: Bool {
        guard let status = paper?.statusEnum else { return false }
        return status.isActive
    }
    private var activeProgress: Double { viewMode == .pdf ? pdfProgress : textProgress }

    private var retranslateActive: Bool {
        retranslateBusy || (retranslateRequestedFor == paperId && paperProcessing && !retranslateRequestedFor.isEmpty)
    }

    private var backgroundRetranslateError: String? {
        guard retranslateRequestedFor == paperId,
              paper?.statusEnum == .error,
              let message = paper?.errorMessage, !message.isEmpty else { return nil }
        return "重新翻译失败:\(message)"
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

            if outlineVisible {
                VStack(alignment: .leading, spacing: 0) {
                    WorkspaceNav(
                        collapsed: readerStore.leftPanelCollapsed,
                        currentPaperId: paperId,
                        onToggleOutline: { readerStore.toggleLeftPanel() }
                    )
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.top, 14)
                .allowsHitTesting(true)
            }

            VStack(alignment: .trailing, spacing: 8) {
                floatingTools
                if retranslateActive {
                    retryBanner(
                        icon: nil,
                        spinner: true,
                        text: "正在重新翻译本文献并重建逻辑链…",
                        color: palette.accent
                    )
                    .transition(.opacity)
                }
                if let error = visibleRetranslateError {
                    retryBanner(icon: Ic.alertTriangle, spinner: false, text: error, color: palette.danger)
                        .transition(.opacity)
                }
            }
            .padding(.top, 14)
            .padding(.trailing, mobile ? 10 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
        .background(palette.gray0)
        .animation(.easeInOut(duration: 0.18), value: retranslateActive)
        .animation(.easeInOut(duration: 0.18), value: visibleRetranslateError == nil)
        .onAppear { hydrateLocalState() }
        .onChange(of: paperId) { _, _ in hydrateLocalState() }
        .onChange(of: readerStore.pendingScrollTarget) { _, target in
            guard target != nil else { return }
            readerStore.consumeScrollTarget()
        }
    }

    private var visibleRetranslateError: String? {
        retranslateError.isEmpty ? backgroundRetranslateError : retranslateError
    }

    private func hydrateLocalState() {
        guard !paperId.isEmpty else { return }
        if viewModeOverride == nil {
            let stored = initialView.flatMap { ReaderViewMode(rawValue: $0) }
                ?? (LocalPrefs.readerMode(paperId: paperId) == "pdf" ? .pdf : .text)
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
        HStack(spacing: mobile ? 5 : 7) {
            toolButton(
                icon: viewMode == .text ? Ic.fileText : Ic.fileType,
                pressed: viewMode == .pdf,
                active: false,
                help: viewMode == .text ? "文本精读,点击查看原始 PDF" : "原始 PDF,点击返回文本精读"
            ) {
                toggleViewMode()
            }

            toolButton(
                icon: readerStore.bilingualMode == .original ? Ic.pilcrow : Ic.languages,
                pressed: readerStore.bilingualMode != .original,
                active: false,
                help: viewMode == .pdf
                    ? "PDF 模式不提供译文切换"
                    : (readerStore.bilingualMode == .original ? "原文模式,点击切换双语" : "双语模式,点击切换原文")
            ) {
                readerStore.setBilingualMode(readerStore.bilingualMode == .original ? .bilingual : .original)
            }
            .disabled(viewMode == .pdf)

            Button {
                Task { await handleRetranslate() }
            } label: {
                HStack(spacing: 6) {
                    if retranslateActive { SpinnerIcon(size: 15) } else { Image.ic(Ic.refresh).font(.system(size: 15)) }
                    if !mobile {
                        Text(retranslateActive ? "重译中" : "重新翻译")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .foregroundStyle(retranslateActive ? palette.accent : palette.accent)
                .frame(minWidth: mobile ? 36 : 96, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(retranslateActive ? palette.accentSoft : palette.gray0.opacity(0.92))
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.accent.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(paper == nil || blocks.isEmpty || paperProcessing || retranslateBusy)
            .help(retranslateActive ? "正在重新翻译并重建逻辑链…" : "重新翻译本文献(补齐缺失译文与逻辑链)")

            HStack(spacing: 5) {
                Image.ic(Ic.gauge).font(.system(size: 13)).foregroundStyle(palette.accent)
                Text("\(Int(activeProgress.rounded()))%")
                    .font(.mono(10, weight: .bold))
                    .foregroundStyle(palette.gray700)
                    .frame(width: 30, alignment: .leading)
            }
            .frame(width: mobile ? 60 : 70, height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(palette.gray0.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.gray300.opacity(0.72)))
            .help("\(viewMode == .pdf ? "PDF" : "文本")阅读进度 \(Int(activeProgress.rounded()))%")

            HStack(spacing: 1) {
                scaleButton(icon: Ic.zoomOut) { changeReadingScale(-1) }
                Text(viewMode == .pdf ? "\(Int((pdfZoom * 100).rounded()))%" : "\(Int(readerStore.fontSize))")
                    .font(.mono(10, weight: .semibold))
                    .foregroundStyle(palette.gray600)
                    .frame(width: 40)
                scaleButton(icon: Ic.zoomIn) { changeReadingScale(1) }
            }
            .frame(width: mobile ? 98 : 112, height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(palette.gray0.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.gray300.opacity(0.72)))
        }
    }

    private func scaleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.ic(icon)
                .font(.system(size: 14))
                .foregroundStyle(palette.gray500)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.clear))
        .contentShape(Rectangle())
    }

    private func toolButton(icon: String, pressed: Bool, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image.ic(icon)
                .font(.system(size: 16))
                .foregroundStyle(pressed ? .white : palette.gray500)
                .frame(minWidth: 40, minHeight: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(pressed ? palette.accent : palette.gray0.opacity(0.92))
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(pressed ? palette.accent : palette.gray300.opacity(0.72)))
        }
        .buttonStyle(.plain)
        .help(help)
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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.06))
                .background(palette.gray0.opacity(0.95), in: RoundedRectangle(cornerRadius: 10))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3)))
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
        defer { retranslateBusy = false }
        do {
            _ = try await client.papersRetranslate(id: paper.id)
            await readerStore.refreshPaper(id: paper.id)
            retranslateRequestedFor = paper.id
        } catch {
            retranslateRequestedFor = ""
            retranslateError = "重新翻译未启动:\(ApiFailure.wrap(error).errorDescription ?? "未知错误")"
        }
    }

    private func handleReparse() async {
        guard let paper else { return }
        _ = try? await client.papersReparse(id: paper.id)
        await readerStore.refreshPaper(id: paper.id)
    }

    // MARK: text reading scroll

    private var textReadingScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                documentBody(proxy: proxy)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ContentFrameKey.self,
                                value: geo.frame(in: .named("readingScroll"))
                            )
                        }
                    )
            }
            .coordinateSpace(name: "readingScroll")
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ReadingViewportKey.self,
                        value: geo.size.height
                    )
                }
            )
            .scrollPadding(top: 88)
            .onPreferenceChange(ReadingViewportKey.self) { viewportHeight = max(1, $0) }
            .onPreferenceChange(BlockFramesKey.self) { frames in
                blockFrames = frames
                updateActiveBlock()
            }
            .onPreferenceChange(ContentFrameKey.self) { frame in
                contentFrame = frame
                updateTextProgress()
            }
            .onChange(of: paperId) { oldId, newId in
                guard oldId != newId, !newId.isEmpty else { return }
                restoreTextProgress(proxy: proxy)
            }
            .onAppear {
                if !paperId.isEmpty { restoreTextProgress(proxy: proxy) }
            }
            .overlay(alignment: .leading) {
                if viewMode == .text, outlineVisible, !mobile {
                    outlineResizeHandle
                }
            }
        }
    }

    private var bottomGeometry: some View {
        Color.clear.frame(height: 1)
    }

    private func restoreTextProgress(proxy: ScrollViewProxy) {
        guard !paperId.isEmpty, restoredForPaper != paperId, !blocks.isEmpty else { return }
        let progress = LocalPrefs.textProgress(paperId: paperId)
        let index = min(blocks.count - 1, max(0, Int(progress / 100 * Double(blocks.count))))
        let blockId = blocks[index].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            proxy.scrollTo(blockId, anchor: .top)
            restoredForPaper = paperId
        }
    }

    private func updateTextProgress() {
        guard paperId.isEmpty == false, blocks.isEmpty == false else { return }
        let maxScroll = max(0, contentFrame.height - viewportHeight)
        let offset = -contentFrame.minY
        var progress: Double
        if maxScroll == 0 || offset <= 1 {
            progress = 0
        } else {
            let endThreshold = max(2, min(32, viewportHeight * 0.04))
            if maxScroll - offset <= endThreshold {
                progress = 100
            } else {
                progress = min(100, max(0, offset / maxScroll * 100))
            }
        }
        if abs(textProgress - progress) >= 0.01 {
            textProgress = progress
        }
        if restoredForPaper == paperId {
            LocalPrefs.setTextProgress(progress, paperId: paperId)
        }
    }

    private func updateActiveBlock() {
        guard !blockFrames.isEmpty else { return }
        let targetY = min(180, viewportHeight * 0.25)
        var closestId = ""
        var closestDistance = CGFloat.infinity
        for frame in blockFrames {
            let distance = abs(frame.minY - targetY)
            if distance < closestDistance {
                closestDistance = distance
                closestId = frame.id
            }
        }
        if !closestId.isEmpty, closestId != readerStore.activeBlockId {
            readerStore.setActiveBlock(closestId)
        }
    }

    private var outlineResizeHandle: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: max(0, leftWidth - 4))
            Rectangle()
                .fill(Color.clear)
                .frame(width: 9)
                .overlay(alignment: .center) {
                    Rectangle()
                        .fill(palette.accent.opacity(0.55))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .opacity(0)
                }
                .overlay(alignment: .center) {
                    Capsule()
                        .fill(palette.accent.opacity(0.4))
                        .frame(width: 2, height: 60)
                        .opacity(0)
                }
                .contentShape(Rectangle())
                .cursor(.resizeLeftRight)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = dragStartWidth ?? leftWidth
                            if dragStartWidth == nil { dragStartWidth = leftWidth }
                            let clamped = min(390, max(190, base + value.translation.width))
                            leftWidth = clamped
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
            Color.clear
        }
        .allowsHitTesting(true)
    }

    @State private var dragStartWidth: CGFloat?

    // MARK: document body

    @ViewBuilder
    private func documentBody(proxy: ScrollViewProxy) -> some View {
        if let paper, !blocks.isEmpty {
            VStack(spacing: 0) {
                documentHeader(paper: paper)
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockRow(block: block, index: index, proxy: proxy)
                }
                documentFooter
            }
            .frame(maxWidth: outlineVisible ? .infinity : 820)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 84)
        } else if let paper, blocks.isEmpty, paper.statusEnum != .error {
            processingStage(paper: paper)
        } else if let paper, paper.statusEnum == .error {
            errorStage(paper: paper)
        }
    }

    private func documentHeader(paper: PaperListItem) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if outlineVisible {
                VStack(alignment: .trailing, spacing: 7) {
                    Text("OUTLINE")
                        .font(.mono(9, weight: .bold))
                        .kerning(1.7)
                        .foregroundStyle(palette.accent)
                    Text("论文逻辑链")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.gray800)
                    Text("\(blocks.count) 个节点")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.gray400)
                }
                .padding(.leading, 22)
                .padding(.trailing, 18)
                .padding(.top, 10)
                .frame(width: leftWidth, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("RESEARCH ARTICLE")
                    .font(.mono(8, weight: .bold))
                    .kerning(1.6)
                    .foregroundStyle(palette.accent)
                Text(paper.displayTitle)
                    .font(.reading(titleSize, weight: .medium))
                    .kerning(-0.6)
                    .lineSpacing(5)
                    .foregroundStyle(palette.gray900)
                    .padding(.vertical, 14)
                    .fixedSize(horizontal: false, vertical: true)
                if !paper.titleZh.isEmpty && paper.titleZh != paper.title {
                    Text(paper.titleZh)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(palette.gray600)
                        .padding(.bottom, 17)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(authorLine(paper))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.gray500)
            }
            .padding(.horizontal, mobile ? 18 : 34)
            .padding(.bottom, 31)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, mobile ? 62 : 94)
    }

    /// Web uses clamp(29px, 3.3vw, 44px) on the document title.
    private var titleSize: CGFloat {
        let containerWidth = contentFrame.width > 10 ? contentFrame.width : 800
        return min(44, max(29, containerWidth * 0.033))
    }

    private func authorLine(_ paper: PaperListItem) -> String {
        let authors = paper.authors.isEmpty
            ? paper.originalFileName
            : paper.authors.prefix(6).joined(separator: " · ")
        return paper.year.map { "\(authors) · \($0)" } ?? authors
    }

    private func blockRow(block: Block, index: Int, proxy: ScrollViewProxy) -> some View {
        let entityMap = Dictionary(uniqueKeysWithValues: (readerStore.paper?.entities ?? []).map { ($0.id, $0) })
        let entities = block.entityRefs.compactMap { entityMap[$0] }
        let isActive = readerStore.activeBlockId == block.id
        let isFlashing = readerStore.flashBlockId == block.id

        return HStack(alignment: .top, spacing: 0) {
            if outlineVisible {
                VStack(spacing: 0) {
                    OutlineNode(
                        block: block,
                        entities: entities,
                        index: index,
                        active: isActive,
                        leading: false,
                        onClick: { readerStore.scrollToBlock(block.id) },
                        onEntityClick: { entity in
                            readerStore.addAttachedContext(AttachedContext(
                                type: "method_card",
                                refBlockId: block.id,
                                refEntityId: entity.id,
                                snippet: entity.name
                            ))
                        }
                    )
                    Spacer(minLength: 0)
                }
                .frame(width: leftWidth, alignment: .top)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .stroke(palette.gray300.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 1)
                        .padding(.trailing, 19)
                        .opacity(0.5)
                }
            }

            BlockRenderer(block: block, readingFontSize: readerStore.fontSize)
                .padding(.horizontal, mobile ? 18 : 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isFlashing ? palette.accentSoft : Color.clear)
                .animation(.easeOut(duration: 1.8), value: isFlashing)
        }
        .padding(.top, blockTopPadding(block))
        .id(block.id)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: BlockFramesKey.self,
                    value: [BlockFrame(id: block.id, minY: geo.frame(in: .named("readingScroll")).minY, height: geo.size.height)]
                )
            }
        )
    }

    private func blockTopPadding(_ block: Block) -> CGFloat {
        switch block.kind {
        case "section_heading": return 39
        case "figure", "table": return 22
        case "equation": return 12
        default: return 0
        }
    }

    private var documentFooter: some View {
        HStack {
            if outlineVisible { Color.clear.frame(width: leftWidth) }
            Rectangle().fill(palette.gray200).frame(height: 1)
                .overlay(alignment: .top) {
                    Text("END OF PAPER")
                        .font(.mono(8, weight: .bold))
                        .kerning(1.5)
                        .foregroundStyle(palette.gray400)
                        .padding(.horizontal, 10)
                        .background(palette.gray0)
                        .offset(y: -5)
                }
                .padding(.horizontal, mobile ? 18 : 34)
                .padding(.top, 65)
        }
    }

    // MARK: stages

    private func processingStage(paper: PaperListItem) -> some View {
        VStack(spacing: 8) {
            Circle()
                .fill(palette.accentSoft)
                .frame(width: 54, height: 54)
                .overlay(ProgressView().controlSize(.regular).tint(palette.accent))
            Text("PREPARING PAPER")
                .font(.mono(10, weight: .bold))
                .kerning(1.6)
                .foregroundStyle(palette.accent)
            Text(paper.statusEnum.processingCopy ?? "正在准备论文内容")
                .font(.reading(24, weight: .medium))
                .foregroundStyle(palette.gray900)
            Text("可以留在此页,完成后正文和逻辑目录会自动出现。")
                .font(.system(size: 11))
                .foregroundStyle(palette.gray500)
            stageRail(status: paper.statusEnum)
        }
        .frame(maxWidth: 520, minHeight: viewportHeight > 1 ? viewportHeight : 520)
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
                .font(.mono(10, weight: .bold))
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
                    .font(.mono(9, weight: .bold))
                    .foregroundStyle(palette.danger)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.danger.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.danger.opacity(0.3)))
            }
            Text(paper.errorMessage.isEmpty ? "请检查 API 配置后重新解析。" : paper.errorMessage)
                .font(.mono(9))
                .foregroundStyle(palette.danger)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.danger.opacity(0.08)))
                .fixedSize(horizontal: false, vertical: true)
            PrimaryActionButton(title: "重新解析", systemImage: Ic.rotateCcw) {
                Task { await handleReparse() }
            }
            .padding(.top, 10)
        }
        .frame(maxWidth: 520, minHeight: viewportHeight > 1 ? viewportHeight : 520)
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Preference keys

struct BlockFrame: Equatable {
    let id: String
    let minY: CGFloat
    let height: CGFloat
}

struct BlockFramesKey: PreferenceKey {
    static var defaultValue: [BlockFrame] = []
    static func reduce(value: inout [BlockFrame], nextValue: () -> [BlockFrame]) {
        value.append(contentsOf: nextValue())
    }
}

struct ReadingViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
