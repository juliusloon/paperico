import SwiftUI

/// One responsive reader shell: document, margin chain, and trailing floating cards.
struct ReaderPage: View {
    let paperId: String

    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppServices.self) private var services
    @Environment(ReaderStore.self) private var readerStore
    @Environment(Router.self) private var router
    @Environment(ChatStore.self) private var chatStore

    @State private var leftWidth: CGFloat = LocalPrefs.leftWidth > 0 ? LocalPrefs.leftWidth : 250
    @State private var rightWidth: CGFloat = LocalPrefs.rightWidth > 0 ? LocalPrefs.rightWidth : 370
    @State private var presentsHiddenPanels = false

    private var paperStatus: PaperStatus? { readerStore.paper?.paper.statusEnum }

    var body: some View {
        Group {
            if readerStore.loading {
                readerState {
                    ProgressView().controlSize(.regular)
                    Text("正在打开论文工作台…")
                }
            } else if readerStore.paper == nil {
                readerState {
                    Image.ic(Ic.alertCircle).font(.system(size: 26))
                    Text(readerStore.error.isEmpty ? "没有找到这篇论文" : readerStore.error)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        PrimaryActionButton(title: "重新载入") {
                            Task { await readerStore.fetchPaper(id: paperId) }
                        }
                        BackToLibraryButton()
                            .buttonStyle(LiquidActionButtonStyle())
                    }
                }
            } else {
                desktopReader
            }
        }
        .background(Color.clear)
        .environment(\.trafficLightClearance, 0)
        .overlay(alignment: .topLeading) {
            if let origin = router.citationReturnPaperId, origin != paperId {
                Button("返回来源对话", systemImage: "arrow.backward") {
                    router.citationReturnPaperId = nil
                    router.go(.reader(paperId: origin))
                }.buttonStyle(.bordered).padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) {
            WorkspaceNav(currentPaperId: paperId, includesDirectory: true,
                         surfaceScheme: colorScheme)
                .padding(14)
        }
        .overlay(alignment: .bottomTrailing) {
            GlassEffectContainer(spacing: 8) {
                if !floatingPanelsFit(containerWidth), !presentsHiddenPanels {
                    RoundIconButton(systemName: Ic.messagesSquare, size: 40,
                                    title: "打开论文信息与对话", foreground: .primary) {
                        presentsHiddenPanels = true
                    }
                    .liquidTool(cornerRadius: 20)
                    .transition(.opacity)
                }
            }
            .padding(14)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: floatingPanelsFit(containerWidth))
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: presentsHiddenPanels)
        }
        .task(id: paperId) { await bootstrap() }
        .task(id: "\(paperId):\(services.pipeline.isProcessing(paperId))") { await pollLoop() }
        .task { await perfLoop() }
        .onChange(of: readerStore.attachedContext.count) { oldValue, newValue in
            guard newValue > oldValue else { return }
            if !floatingPanelsFit(containerWidth) { presentsHiddenPanels = true }
        }
    }

    private func bootstrap() async {
        chatStore.bind(to: paperId)
        LocalPrefs.lastPaperId = paperId
        let startedAt = ReaderPerf.start("reader.open(\(paperId))")
        if readerStore.paper?.paper.id != paperId {
            await readerStore.fetchPaper(id: paperId)
        }
        guard !Task.isCancelled else { return }
        await chatStore.fetchSessions(paperId: paperId)
        guard !Task.isCancelled else { return }
        if let source = router.pendingCitationSource, source.paperId == paperId {
            if let blockId = source.blockId { readerStore.scrollToBlock(blockId, centered: true) }
            router.pendingCitationSource = nil
        }
        ReaderPerf.end("reader.open(\(paperId))", startedAt: startedAt)
    }

    /// 轮询改成"轻量 status + 按需整篇重载"。
    ///
    /// 原来在论文处于 processing 状态时,每 3.5s 拉一次完整的 paper detail
    /// (实测 414 KB / 181 block),替换 store 里的整个 `paper` → 文档里每一个
    /// 视图失效重建。处理中的论文几乎点不动,就是这个循环造成的。
    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if Task.isCancelled { return }
            // 已就绪/出错:没有再轮询的必要,直接退出循环。
            guard let current = paperStatus,
                  current.isActive || services.pipeline.isProcessing(paperId) else { return }
            guard let status = await services.pipeline.status(paperId: paperId) else { continue }
            let next = PaperStatus(raw: status.status)
            // 同一阶段只更新轻量状态；单次分析全部校验落盘后才整篇刷新。
            if next == current {
                readerStore.applyStatus(status)
                continue
            }
            await readerStore.refreshPaper(id: paperId)
            if !next.isActive { return }
        }
    }

    /// 性能采样输出(默认关闭,见 Support/ReaderPerf.swift)。
    private func perfLoop() async {
        guard ReaderPerf.isEnabled else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            ReaderPerf.dumpSummary()
        }
    }

    private func readerState<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            content()
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.gray500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.insetSurface)
    }

    // MARK: desktop shell

    private var desktopReader: some View {
        GeometryReader { shell in
            let visible = floatingPanelsFit(shell.size.width)
            let drawerWidth = visible ? rightWidth : min(rightWidth, max(0, shell.size.width * 0.5 - 12))
            ZStack(alignment: .trailing) {
                ReadingArea(toolsObscured: presentsHiddenPanels && !visible, leftWidth: $leftWidth)
                    .padding(.trailing, visible ? rightWidth + 24 : 0)
                if !visible, presentsHiddenPanels {
                    OutsideDismissArea(label: "关闭论文信息与对话") { presentsHiddenPanels = false }
                        .background(.black.opacity(0.08))
                        .transition(.opacity)
                }
                // Keep the card and chat state mounted when switching between inline and drawer presentation.
                RightPanel()
                    .environment(\.drawerSurface, !visible && presentsHiddenPanels)
                    .frame(width: drawerWidth)
                    .padding(.trailing, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .padding(.leading, 12)
                    .offset(x: visible || presentsHiddenPanels ? 0 : drawerWidth + 24)
                    .allowsHitTesting(visible || presentsHiddenPanels)
                    .accessibilityHidden(!visible && !presentsHiddenPanels)
                if visible {
                    resizeHandle(shellWidth: shell.size.width)
                        .frame(width: 12)
                        .padding(.trailing, rightWidth + 12)
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: presentsHiddenPanels)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: visible)
            .onChange(of: visible) { _, inline in
                if inline { presentsHiddenPanels = false }
            }
            .onExitCommand { presentsHiddenPanels = false }
        }
    }

    private func floatingPanelsFit(_ width: CGFloat) -> Bool {
        // Both document modes use the same shell breakpoint, so switching to
        // PDF never moves the toolbar by suddenly inserting the right cards.
        let outline = !readerStore.leftPanelCollapsed && width >= LayoutBreakpoint.reader ? leftWidth : 0
        return width >= max(LayoutBreakpoint.reader, outline + 500 + rightWidth + 24)
    }

    private func resizeHandle(shellWidth: CGFloat) -> some View {
        ReaderDivider(axis: .horizontal, label: "调整右侧卡片宽度") { translation in
            let base = dragStartRightWidth ?? rightWidth
            if dragStartRightWidth == nil { dragStartRightWidth = rightWidth }
            let candidate = base - translation
            let clamped = min(520, max(310, candidate))
            let outline = !readerStore.leftPanelCollapsed && shellWidth >= LayoutBreakpoint.reader ? leftWidth : 0
            let limit = shellWidth - outline - 500 - 24
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rightWidth = max(310, min(clamped, max(310, limit)))
            }
        } onEnd: {
            dragStartRightWidth = nil
            LocalPrefs.rightWidth = rightWidth
        }
    }

    @State private var dragStartRightWidth: CGFloat?

}

struct BackToLibraryButton: View {
    @Environment(Router.self) private var router

    var body: some View {
        Button("返回论文库") {
            router.go(.library)
        }
    }
}
