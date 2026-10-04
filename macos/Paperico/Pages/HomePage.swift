import SwiftUI

/// Home overview with recent papers and the core evidence reading workflow.
/// 所有窗口保留桌面内容层级，插图始终在文字右侧。
struct HomePage: View {
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(PapersStore.self) private var papersStore
    @Environment(ProjectsStore.self) private var projectsStore
    @Environment(Router.self) private var router

    private var compact: Bool { containerWidth < 650 }
    private var cardPadding: CGFloat { compact ? 16 : 24 }
    private var artworkWidth: CGFloat { min(300, max(120, containerWidth * 0.24)) }
    private var heroTitleSize: CGFloat {
        let copyWidth = min(1240, containerWidth - 44) - 40 - artworkWidth - max(18, min(48, containerWidth * 0.035))
        return min(50, max(24, copyWidth / 8.5))
    }

    var body: some View {
        scrollContent
            .overlay(alignment: .bottomLeading) {
                WorkspaceNav().padding(14)
            }
            .background(Color.clear)
        .task {
            await papersStore.fetch()
            await projectsStore.fetch()
        }
    }

    private var scrollContent: some View {
        ScrollView {
            GlassEffectContainer(spacing: 4) {
                VStack(spacing: 10) {
                    hero
                    metrics
                    lowerGrid
                }
            }
            // 所有模块共用内容宽度,缩放窗口时保持同一条左右边线。
            .frame(maxWidth: 1240)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            // Match the split workspace's sidebar: 14 + (clearance - 8).
            .trafficLightTopPadding(6)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private var readyCount: Int {
        papersStore.papers.filter { $0.statusEnum == .ready }.count
    }

    // MARK: hero

    private var hero: some View {
        return HStack(alignment: .center, spacing: max(18, min(48, containerWidth * 0.035))) {
            heroCopy
            OrbitArt()
                .frame(width: 300, height: 280)
                .scaleEffect(artworkWidth / 300)
                .frame(width: artworkWidth, height: artworkWidth * 280 / 300)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 250 : 300, alignment: .leading)
        .padding(20)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("读懂论文，\n让判断有据可循。")
                .font(.system(size: heroTitleSize, weight: .medium))
                .kerning(-0.8)
                .lineSpacing(6)
                .foregroundStyle(palette.gray900)
                .lineLimit(2).minimumScaleFactor(0.75)

            Text("把论文读成逻辑链，让每次追问回到原文证据。")
                .font(.system(size: compact ? 13.5 : 16.5))
                .lineSpacing(7)
                .foregroundStyle(palette.gray600)
                .padding(.top, 22)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { heroActions }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 10) { heroActions }
            }
            .padding(.top, compact ? 18 : 26)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var heroActions: some View {
        PrimaryActionButton(title: "打开论文库", systemImage: Ic.arrowRight) {
            router.go(.library)
        }
        SecondaryActionButton(title: "检查 API 配置") {
            router.go(.settings)
        }
    }

    // MARK: metrics

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(icon: Ic.library, value: papersStore.papers.count, label: "篇论文")
            divider
            metric(icon: Ic.bookOpen, value: readyCount, label: "已完成解析")
            divider
            metric(icon: Ic.brain, value: projectsStore.projects.count, label: "个研究项目")
        }
        .frame(maxWidth: .infinity)
        .liquidPanel()
        .padding(.top, 10)
    }

    private var divider: some View {
        Rectangle().fill(palette.gray200).frame(width: 1, height: 40)
    }

    private func metric(icon: String, value: Int, label: String) -> some View {
        VStack(spacing: compact ? 4 : 0) {
            HStack(spacing: compact ? 6 : 10) {
                Image.ic(icon)
                    .font(.system(size: 16))
                    .foregroundStyle(palette.accent)
                Text("\(value)")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(palette.gray900)
                if !compact {
                    Text(label).font(.system(size: 13)).foregroundStyle(palette.gray500)
                }
            }
            if compact {
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.gray500)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 70)
    }

    // MARK: lower grid

    private var lowerGrid: some View {
        HomeCardRow {
            recentPanel.frame(maxWidth: .infinity, alignment: .leading)
            workflowPanel
        }
        .frame(maxWidth: .infinity)
    }

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("继续阅读")
                        .font(.system(size: compact ? 19 : 21, weight: .medium))
                        .foregroundStyle(palette.gray900)
                }
                Spacer(minLength: 0)
                Button {
                    router.go(.library)
                } label: {
                    HStack(spacing: 5) {
                        if !compact { Text("查看全部") }
                        Image.ic(Ic.arrowRight).font(.system(size: 10))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(palette.gray500)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 14)

            let recent = Array(papersStore.papers.prefix(4))
            if recent.isEmpty {
                HStack(spacing: 8) {
                    Image.ic(Ic.fileSearch).font(.system(size: 24))
                    Text("还没有论文。前往论文库上传第一份 PDF。")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.gray400)
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, paper in
                        recentRow(index: index, paper: paper)
                    }
                }
            }
        }
        .padding(cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .liquidPanel()
    }

    private func recentRow(index: Int, paper: PaperListItem) -> some View {
        Button {
            router.go(.reader(paperId: paper.id))
        } label: {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.gray400)
                VStack(alignment: .leading, spacing: 4) {
                    Text(paper.displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.gray800)
                        .lineLimit(1)
                    Text(paper.statusEnum == .ready ? (paper.tldr.isEmpty ? "已完成解析" : paper.tldr)
                         : (paper.statusEnum == .uploaded ? "已导入，等待解析" : "正在准备阅读内容"))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.gray500)
                        .lineLimit(1)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                StatusDot(status: paper.statusEnum)
                if !compact { Image.ic(Ic.arrowRight)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.gray500)
                }
            }
            .padding(.vertical, 8)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.gray200).frame(height: index == 0 ? 1 : 0.5).opacity(index == 0 ? 1 : 0.6)
        }
    }

    private var workflowPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("从论文到有据可查的理解")
                .font(.system(size: compact ? 19 : 21, weight: .medium)).foregroundStyle(palette.gray900)
            researchFeature(icon: Ic.listTree, title: "双语阅读，顺着论证走", detail: "原文与译文逐段对照，逻辑链串起要点；正文与 PDF 可按段互跳。")
            researchFeature(icon: Ic.messagesSquare, title: "每次追问，回到证据", detail: "选中段落或图表直接提问，点击回答引用定位原文；对话与笔记留在本机。")
            researchFeature(icon: Ic.layers, title: "跨论文，归集方法", detail: "方法自动归入全库索引，合并同名条目，沿出现位置查看各篇论文如何使用。")
        }
        .padding(cardPadding).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).liquidPanel()
    }

    private func researchFeature(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: compact ? 8 : 13) {
            Image.ic(icon).font(.system(size: 15)).foregroundStyle(palette.accent)
                .frame(width: 34, height: 34).liquidInset(cornerRadius: CornerRadius.inset, tint: palette.accentFaint)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.gray800)
                Text(detail).font(.system(size: 12)).foregroundStyle(palette.gray500).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

}

/// Measure both cards at their final widths, then propose the same row height.
/// Unlike an unconstrained HStack in a ScrollView, this also stretches short cards.
private struct HomeCardRow: Layout {
    private func widths(_ width: CGFloat) -> (leading: CGFloat, trailing: CGFloat, spacing: CGFloat) {
        let spacing = min(22, max(12, width * 0.018))
        let trailing = min(420, max(208, (width - spacing) * 0.43))
        return (max(0, width - trailing - spacing), trailing, spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 1000
        let dimensions = widths(width)
        var height: CGFloat = 0
        for (view, cardWidth) in zip(subviews, [dimensions.leading, dimensions.trailing]) {
            height = max(height, view.sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let dimensions = widths(bounds.width)
        var x = bounds.minX
        for (view, width) in zip(subviews, [dimensions.leading, dimensions.trailing]) {
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + dimensions.spacing
        }
    }
}

// MARK: - Decorative orbit artwork (CSS art redrawn with shapes)

struct OrbitArt: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("论文")
                    .font(.system(size: 9, weight: .bold))
                    .kerning(1.1)
                    .foregroundStyle(palette.accent)
                orbitLines
                    .frame(width: 129, alignment: .leading)
                    .padding(.leading, 29)
                    .padding(.top, 26)
            }
            .frame(width: 158, height: 210, alignment: .topLeading)
            .padding(20)
            .background(palette.gray0, in: Rectangle())
            .shadow(color: palette.accent.opacity(0.10), radius: 0, x: 10, y: 12)
            .shadow(color: palette.shadowCard, radius: 10, y: 6)
            .overlay(Rectangle().stroke(palette.gray200))
            .rotationEffect(.degrees(3))

            orbitRail

            VStack {
                Text("结构化\n精读")
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .foregroundStyle(palette.accentForeground)
            }
            .frame(width: 66, height: 66)
            .background(Circle().fill(palette.accent))
            .rotationEffect(.degrees(-8))
            .offset(x: 105, y: 92)
        }
        .frame(height: 280)
        .accessibilityHidden(true)
    }

    private var orbitLines: some View {
        VStack(alignment: .leading, spacing: 11) {
            Rectangle().fill(palette.gray200).frame(height: 2)
            Rectangle().fill(palette.gray200).frame(height: 2).frame(width: 74, alignment: .leading)
            Rectangle().fill(palette.gray200).frame(height: 2)
            Rectangle().fill(palette.gray200).frame(height: 2)
            Rectangle().fill(palette.gray200).frame(height: 2).frame(width: 74, alignment: .leading)
        }
    }

    private var orbitRail: some View {
        VStack {
            railDot
            Spacer(minLength: 8)
            railDot
            Spacer(minLength: 8)
            railDot
        }
        .frame(width: 158, height: 130)
        .offset(x: -49, y: -8)
        .accessibilityHidden(true)
    }

    private var railDot: some View {
        Circle()
            .fill(palette.accent)
            .frame(width: 8, height: 8)
            .background(Circle().fill(palette.accentSoft).frame(width: 16, height: 16))
    }
}
