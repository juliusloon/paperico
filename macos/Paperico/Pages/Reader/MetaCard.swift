import SwiftUI

/// Paper overview: publication, title, compact facts and a readable summary.
struct MetaCard: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore

    var body: some View {
        if let detail = readerStore.paper {
            ScrollView {
                overview(detail).padding(20)
            }
        }
    }

    private func overview(_ detail: PaperDetail) -> some View {
        let paper = detail.paper
        let characters = detail.blocks.reduce(0) { $0 + $1.textOriginal.count }
        let minutes = max(1, Int((Double(characters) / 1100).rounded()))
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(paper.displayTitle)
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(palette.gray900)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                if !paper.titleZh.isEmpty && paper.titleZh != paper.displayTitle {
                    Text(paper.titleZh).font(.system(size: 13)).foregroundStyle(palette.gray600)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                if !paper.authors.isEmpty {
                    Text(paper.authors.prefix(6).joined(separator: " · ") + (paper.authors.count > 6 ? " 等" : ""))
                        .font(.system(size: 11)).foregroundStyle(palette.gray500).lineSpacing(3)
                }
                if !paper.venue.isEmpty || paper.year != nil {
                    HStack(spacing: 8) {
                        if !paper.venue.isEmpty { Text(paper.venue) }
                        if let year = paper.year { Text(String(year)) }
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.gray600)
                }
            }
            HStack {
                Text(paper.metaSource == MetaSource.manual ? "手动" : (paper.metaSource == MetaSource.auto ? "已识别" : "本地"))
                    .font(.system(size: 11)).foregroundStyle(palette.gray600)
                    .padding(.horizontal, 8).padding(.vertical, 4).liquidInset(cornerRadius: ControlSpec.radius)
                Spacer()
            }
            if paper.doi != nil || paper.arxivId != nil {
                VStack(alignment: .leading, spacing: 5) {
                    if let doi = paper.doi, !doi.isEmpty { Text("DOI：\(doi)") }
                    if let arxiv = paper.arxivId, !arxiv.isEmpty { Text("arXiv：\(arxiv)") }
                }.font(.system(size: 11)).foregroundStyle(palette.gray600).textSelection(.enabled)
            }
            HStack(spacing: 14) {
                fact("\(minutes) 分钟", icon: "clock")
                fact("\(PaperOutline.entries(detail.blocks).count) 节点", icon: "text.alignleft")
                if !paper.difficultyEstimate.isEmpty { fact(paper.difficultyEstimate, icon: "gauge.with.dots.needle.50percent") }
            }
            if !paper.domainTags.isEmpty {
                FlowChips {
                    ForEach(paper.domainTags, id: \.self) { tag in
                        Text(tag).font(.system(size: 11)).foregroundStyle(palette.gray600)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .liquidInset(cornerRadius: ControlSpec.radius)
                    }
                }
            }
            if !paper.tldr.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Capsule().fill(palette.accent.opacity(0.7)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("研究要点").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accent)
                        Text(paper.tldr).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.gray800).lineSpacing(5)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !paper.narrativeSummary.isEmpty {
                summary("全文主线") { Text(paper.narrativeSummary).summaryBody(palette: palette) }
            }
            if !paper.contributions.isEmpty {
                summary("核心贡献") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(paper.contributions.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.gray500)
                                Text(item).summaryBody(palette: palette)
                            }
                        }
                    }
                }
            }
            if !detail.entities.isEmpty {
                summary("方法与实体 · \(detail.entities.count)") {
                    FlowChips {
                        ForEach(detail.entities.prefix(18)) { entity in
                            Button {
                                readerStore.highlightEntities([entity.id])
                                if let first = entity.blockRefs.first { readerStore.scrollToBlock(first, centered: true) }
                            } label: {
                                Text(entity.name).font(.system(size: 11)).foregroundStyle(palette.accent)
                                    .lineLimit(2).padding(.horizontal, 9).padding(.vertical, 6)
                                    .background(palette.accentSoft.opacity(0.65), in: Capsule())
                            }.buttonStyle(.plain)
                                .help(entity.definitionZh.isEmpty ? entity.category : entity.definitionZh)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func fact(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 11)).foregroundStyle(palette.gray500)
            .lineLimit(1)
    }

    private func summary<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider().opacity(0.5)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.gray500)
            content()
        }
    }
}

extension Text {
    func summaryBody(palette: Palette) -> some View {
        font(.system(size: 13)).lineSpacing(5).foregroundStyle(palette.gray700)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Wrap at each chip's intrinsic width so names do not break into tiny columns.
struct FlowChips<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }
    var body: some View { WrappingChipsLayout(spacing: spacing) { content() } }
}

private struct WrappingChipsLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .greatestFiniteMagnitude).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (index, point) in result.positions.enumerated() {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                                  anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: min(width, usedWidth), height: y + rowHeight), positions)
    }
}
