import SwiftUI

/// Mirrors reader/RightPanel.tsx — 论文信息 + 论文对话 stacked cards with a
/// draggable vertical splitter on desktop, DisclosureGroup sheet on mobile.
struct RightPanel: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore

    @State private var stackHeight: CGFloat = 0
    @State private var topHeight: CGFloat?

    private var paperId: String { readerStore.paper?.paper.id ?? "" }

    private let cardHeader: CGFloat = 48
    private let splitterSize: CGFloat = 10

    private var resolvedTop: CGFloat {
        let fallback = stackHeight * 0.4
        let value = topHeight ?? fallback
        return min(max(value, cardHeader), max(cardHeader, stackHeight - cardHeader - splitterSize))
    }

    private var infoCollapsed: Bool { resolvedTop <= cardHeader + 2 }
    private var chatCollapsed: Bool { stackHeight > 0 && (stackHeight - resolvedTop - splitterSize) <= cardHeader + 2 }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                sideCard(header: infoHeader, collapsed: infoCollapsed) {
                    MetaCard()
                }
                .frame(height: max(cardHeader, resolvedTop))

                resizer
                    .frame(height: splitterSize)

                sideCard(header: chatHeader, collapsed: chatCollapsed) {
                    ChatPanel(paperId: paperId)
                }
                .frame(maxHeight: .infinity)
            }
            .onAppear { stackHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, newValue in
                stackHeight = newValue
                if let current = topHeight {
                    topHeight = min(max(current, cardHeader), max(cardHeader, newValue - cardHeader - splitterSize))
                }
            }
        }
    }

    private var infoHeader: some View {
        CardTitleBar(systemImage: Ic.fileText, title: "论文信息", code: "INFO") {
            topHeight = stackHeight - cardHeader - splitterSize
        }
    }

    private var chatHeader: some View {
        CardTitleBar(systemImage: Ic.messageCircle, title: "论文对话", code: "CHAT") {
            topHeight = cardHeader
        }
    }

    private var resizer: some View {
        ZStack {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
            Capsule()
                .fill(palette.gray200)
                .frame(width: 38, height: 3)
        }
        .cursor(.resizeUpDown)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = dragStartTopHeight ?? resolvedTop
                    if dragStartTopHeight == nil { dragStartTopHeight = resolvedTop }
                    topHeight = min(max(base + value.translation.height, cardHeader), max(cardHeader, stackHeight - cardHeader - splitterSize))
                }
                .onEnded { _ in dragStartTopHeight = nil }
        )
    }

    @State private var dragStartTopHeight: CGFloat?

    @ViewBuilder
    private func sideCard<Content: View>(header: some View, collapsed: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                content()
                    .frame(maxHeight: .infinity)
            }
        }
        .liquidPanel(cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private struct CardTitleBar: View {
        @Environment(\.palette) private var palette
        let systemImage: String
        let title: String
        let code: String
        let onMaximize: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Image.ic(systemImage).font(.system(size: 15)).foregroundStyle(palette.accent)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.gray700)
                Text(code).font(.mono(8, weight: .bold)).kerning(1.3).foregroundStyle(palette.gray400)
                Spacer(minLength: 0)
                RoundIconButton(systemName: Ic.maximize, size: 30, title: "\(title)占据整列") {
                    onMaximize()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Color.clear)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.gray100).frame(height: 1) }
        }
    }
}

/// Mobile "信息与对话" pane (mirrors MobileSidePanel).
struct MobileSidePanel: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore
    @State private var infoExpanded = false

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { infoExpanded.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image.ic(Ic.fileText).font(.system(size: 14)).foregroundStyle(palette.accent)
                        Text("论文信息").font(.system(size: 14)).foregroundStyle(palette.gray800)
                        Text("INFO").font(.mono(7, weight: .bold)).kerning(1.4).foregroundStyle(palette.gray400)
                        Spacer(minLength: 0)
                        Image.ic(Ic.chevronDown)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.gray400)
                            .rotationEffect(.degrees(infoExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if infoExpanded {
                    MetaCard()
                        .frame(maxHeight: 260)
                        .overlay(alignment: .top) { Rectangle().fill(palette.gray100).frame(height: 1) }
                }
            }
            .liquidPanel(cornerRadius: 15)

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image.ic(Ic.messageCircle).font(.system(size: 15)).foregroundStyle(palette.accent)
                    Text("论文对话").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.gray700)
                    Text("CHAT").font(.mono(8, weight: .bold)).kerning(1.3).foregroundStyle(palette.gray400)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.gray100).frame(height: 1) }

                ChatPanel(paperId: readerStore.paper?.paper.id ?? "")
            }
            .liquidPanel(cornerRadius: 15)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Cursor helpers (macOS)

enum CursorKind {
    case resizeUpDown, resizeLeftRight
}

extension View {
    @ViewBuilder
    func cursor(_ kind: CursorKind) -> some View {
        self.onHover { inside in
            setHoverCursor(kind, active: inside)
        }
    }
}

private func setHoverCursor(_ kind: CursorKind, active: Bool) {
    #if os(macOS)
    if active {
        switch kind {
        case .resizeUpDown: NSCursor.resizeUpDown.push()
        case .resizeLeftRight: NSCursor.resizeLeftRight.push()
        }
    } else {
        NSCursor.pop()
    }
    #endif
}
