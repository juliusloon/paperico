import SwiftUI

struct RightPanel: View {
    @Environment(ReaderStore.self) private var readerStore
    @State private var stackHeight: CGFloat = 0
    @State private var topHeight: CGFloat?
    @State private var dragStartTopHeight: CGFloat?
    private let splitterSize: CGFloat = 10
    private var resolvedTop: CGFloat {
        let maximum = max(100, stackHeight - 250 - splitterSize)
        return min(max(topHeight ?? stackHeight * 0.36, 100), maximum)
    }
    var body: some View {
        GeometryReader { geometry in
            GlassGroup(spacing: 4) {
            VStack(spacing: 0) {
                MetaCard().frame(height: resolvedTop).liquidPanel()
                ReaderDivider(axis: .vertical, label: "调整信息与对话卡片高度") { translation in
                    if dragStartTopHeight == nil { dragStartTopHeight = resolvedTop }
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        topHeight = min(max((dragStartTopHeight ?? resolvedTop) + translation, 100), max(100, stackHeight - 260))
                    }
                } onEnd: { dragStartTopHeight = nil }
                .frame(height: splitterSize)
                ChatPanel(paperId: readerStore.paper?.paper.id ?? "")
                    .frame(maxHeight: .infinity).liquidPanel()
            }
            }
            .environment(\.floatingSurface, true)
            .onAppear { stackHeight = geometry.size.height }
            .onChange(of: geometry.size.height) { _, height in stackHeight = height }
        }
    }
}
