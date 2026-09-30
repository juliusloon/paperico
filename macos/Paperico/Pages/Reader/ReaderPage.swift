import SwiftUI

/// Mirrors reader/ReaderPage.tsx — three-column desktop shell with draggable
/// splitters, tabbed panes on narrow width (web ≤900px breakpoint), status polling.
struct ReaderPage: View {
    let paperId: String

    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(\.apiClient) private var client
    @Environment(ReaderStore.self) private var readerStore
    @Environment(ChatStore.self) private var chatStore

    enum MobileTab: Hashable {
        case outline, reading, chat
    }

    @State private var leftWidth: CGFloat = LocalPrefs.leftWidth > 0 ? LocalPrefs.leftWidth : 250
    @State private var rightWidth: CGFloat = LocalPrefs.rightWidth > 0 ? LocalPrefs.rightWidth : 370
    @State private var mobileTab: MobileTab = .reading
    @State private var visitedTabs: Set<MobileTab> = [.reading]

    private var isCompact: Bool { containerWidth < LayoutBreakpoint.reader }
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
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            } else if isCompact {
                mobileReader
            } else {
                desktopReader
            }
        }
        .background(palette.gray100)
        .task { await bootstrap() }
    }

    private func bootstrap() async {
        LocalPrefs.lastPaperId = paperId
        let startedAt = ReaderPerf.start("reader.open(\(paperId))")
        if readerStore.paper?.paper.id != paperId {
            await readerStore.fetchPaper(id: paperId)
        }
        await chatStore.fetchSessions(paperId: paperId)
        ReaderPerf.end("reader.open(\(paperId))", startedAt: startedAt)
        await perfLoop()
        await pollLoop()
    }

    /// 轮询改成"轻量 status + 按需整篇重载"。
    ///
    /// 原来在论文处于 processing 状态时,每 3.5s 拉一次完整的 paper detail
    /// (实测 414 KB / 181 block),替换 store 里的整个 `paper` → 文档里每一个
    /// 视图失效重建。处理中的论文几乎点不动,就是这个循环造成的。
    private func pollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if Task.isCancelled { return }
            // 已就绪/出错:没有再轮询的必要,直接退出循环。
            guard let current = paperStatus, current.isActive else { return }

            tick += 1
            guard let status = try? await client.papersStatus(id: paperId) else { continue }
            let next = PaperStatus(raw: status.status)
            // 状态真的变了才整篇重载;否则每 4 个 tick(≈14s)补一次全量,
            // 保证新解析出来的正文还是会陆续出现。
            if next == current, tick % 4 != 0 {
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
        ReaderPerf.frameIntervals.reset()
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
        .background(palette.gray50)
    }

    // MARK: desktop shell

    private var desktopReader: some View {
        GeometryReader { shell in
            HStack(spacing: 0) {
                ReadingArea(leftWidth: $leftWidth)
                    .frame(maxWidth: .infinity)

                resizeHandle(shellWidth: shell.size.width)
                    .frame(width: 8)

                RightPanel()
                    .padding(.trailing, 12)
                    .padding(.vertical, 12)
                    .frame(width: rightWidth)
            }
        }
        .onChange(of: leftWidth) { _, value in LocalPrefs.leftWidth = value }
        .onChange(of: rightWidth) { _, value in LocalPrefs.rightWidth = value }
    }

    private func resizeHandle(shellWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(palette.gray0)
                .contentShape(Rectangle())
            Capsule()
                .fill(palette.gray300.opacity(0.68))
                .frame(width: 2, height: 34)
        }
        .cursor(.resizeLeftRight)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = dragStartRightWidth ?? rightWidth
                    if dragStartRightWidth == nil { dragStartRightWidth = rightWidth }
                    let candidate = base - value.translation.width
                    let clamped = min(520, max(310, candidate))
                    let limit = shellWidth - (readerStore.leftPanelCollapsed ? 0 : leftWidth) - 520
                    rightWidth = max(310, min(clamped, max(310, limit)))
                }
                .onEnded { _ in dragStartRightWidth = nil }
        )
    }

    @State private var dragStartRightWidth: CGFloat?

    // MARK: compact shell

    private var mobileReader: some View {
        VStack(spacing: 0) {
            mobileTopBar
            ZStack {
                ReadingArea(mobile: true, leftWidth: .constant(240))
                    .opacity(mobileTab == .reading ? 1 : 0)
                    .allowsHitTesting(mobileTab == .reading)

                if visitedTabs.contains(.outline) {
                    MobileOutline(
                        onNavigate: { blockId in
                            switchTab(.reading)
                            readerStore.scrollToBlock(blockId)
                        },
                        onEntityChat: { entity, blockId in
                            readerStore.addAttachedContext(AttachedContext(
                                type: "method_card",
                                refBlockId: blockId,
                                refEntityId: entity.id,
                                snippet: entity.name
                            ))
                            switchTab(.chat)
                        }
                    )
                    .opacity(mobileTab == .outline ? 1 : 0)
                    .allowsHitTesting(mobileTab == .outline)
                }
                if visitedTabs.contains(.chat) {
                    MobileSidePanel()
                        .opacity(mobileTab == .chat ? 1 : 0)
                        .allowsHitTesting(mobileTab == .chat)
                }
            }
        }
        .background(palette.gray0)
    }

    private var mobileTopBar: some View {
        CompactTopBar(currentPaperId: paperId) {
            tabStrip
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            mobileTabButton(.outline, label: "逻辑链", icon: Ic.listTree)
            mobileTabButton(.reading, label: "正文", icon: Ic.bookText)
            mobileTabButton(.chat, label: "对话", icon: Ic.messagesSquare, badge: readerStore.attachedContext.count)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.gray50))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.gray200))
    }

    private func mobileTabButton(_ tab: MobileTab, label: String, icon: String, badge: Int = 0) -> some View {
        let active = mobileTab == tab
        return Button {
            switchTab(tab)
        } label: {
            HStack(spacing: 5) {
                Image.ic(icon).font(.system(size: 14))
                Text(label).font(.system(size: 12, weight: .semibold))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.mono(9, weight: .bold))
                        .foregroundStyle(active ? .white : palette.accent)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(
                            Capsule().fill(active ? Color.white.opacity(0.24) : palette.accentSoft)
                        )
                }
            }
            .foregroundStyle(active ? .white : palette.gray500)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(active ? palette.accent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .noFocusRing()
    }

    private func switchTab(_ tab: MobileTab) {
        mobileTab = tab
        visitedTabs.insert(tab)
    }
}

struct BackToLibraryButton: View {
    @Environment(Router.self) private var router

    var body: some View {
        Button("返回论文库") {
            router.go(.library)
        }
    }
}
