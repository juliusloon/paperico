import SwiftUI

/// Mirrors reader/MetaCard.tsx — the 论文信息 card.
struct MetaCard: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore

    var body: some View {
        Group {
            if let detail = readerStore.paper {
                ScrollView {
                    body(for: detail)
                }
            }
        }
    }

    private func body(for detail: PaperDetail) -> some View {
        let paper = detail.paper
        let characterCount = detail.blocks.reduce(0) { $0 + $1.textOriginal.count }
        let readingMinutes = max(1, Int((Double(characterCount) / 1100.0).rounded()))

        return VStack(alignment: .leading, spacing: 0) {
            Text(paper.venue.isEmpty ? "RESEARCH PAPER" : paper.venue)
                .font(.mono(10, weight: .bold))
                .kerning(1.2)
                .foregroundStyle(palette.accent)
            Text(paper.displayTitle)
                .font(.reading(19.5, weight: .medium))
                .lineSpacing(4)
                .foregroundStyle(palette.gray900)
                .padding(.top, 9)
                .fixedSize(horizontal: false, vertical: true)

            if !paper.titleZh.isEmpty && paper.titleZh != paper.title {
                Text(paper.titleZh)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(palette.gray500)
                    .padding(.top, 9)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !paper.authors.isEmpty {
                Text(paper.authors.prefix(6).joined(separator: " · ") + (paper.authors.count > 6 ? " 等" : ""))
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(palette.gray600)
                    .padding(.top, 9)
            }

            HStack(spacing: 11) {
                HStack(spacing: 4) {
                    Image.ic(Ic.clock).font(.system(size: 10)).foregroundStyle(palette.accent)
                    Text("\(readingMinutes)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(palette.gray700)
                    Text("分钟").font(.system(size: 11.5)).foregroundStyle(palette.gray500)
                }
                HStack(spacing: 4) {
                    Image.ic(Ic.fileText).font(.system(size: 10)).foregroundStyle(palette.accent)
                    Text("\(detail.blocks.count)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(palette.gray700)
                    Text("节点").font(.system(size: 11.5)).foregroundStyle(palette.gray500)
                }
                HStack(spacing: 4) {
                    Image.ic(Ic.gauge).font(.system(size: 10)).foregroundStyle(palette.accent)
                    Text(paper.difficultyEstimate.isEmpty ? "待评估" : paper.difficultyEstimate)
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(palette.gray700)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            .padding(.top, 4)
            .overlay(alignment: .top) { Rectangle().fill(palette.gray100).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(palette.gray100).frame(height: 1) }
            .padding(.top, 9)

            if !paper.domainTags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(paper.domainTags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(palette.accentSoft))
                    }
                }
                .padding(.top, 10)
            }

            if !paper.tldr.isEmpty {
                summarySection(title: "一句话总结", systemImage: Ic.sparkles, featured: true) {
                    Text(paper.tldr).summaryBody(palette: palette)
                }
            }

            if !paper.narrativeSummary.isEmpty {
                summarySection(title: "全文主线", systemImage: nil, featured: false) {
                    Text(paper.narrativeSummary).summaryBody(palette: palette)
                }
            }

            if !paper.contributions.isEmpty {
                summarySection(title: "核心贡献", systemImage: nil, featured: false) {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(paper.contributions.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(index + 1).").foregroundStyle(palette.gray500)
                                Text(item).summaryBody(palette: palette)
                            }
                        }
                    }
                }
            }

            if !detail.entities.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("方法与实体").font(.system(size: 12, weight: .bold)).foregroundStyle(palette.gray700)
                        Spacer(minLength: 0)
                        Text("\(detail.entities.count)").font(.system(size: 12)).foregroundStyle(palette.accent)
                    }
                    .padding(.top, 13)
                    .overlay(alignment: .top) { Rectangle().fill(palette.gray100).frame(height: 1) }

                    FlowChips(maxWidth: 18) {
                        ForEach(detail.entities.prefix(18)) { entity in
                            Button {
                                readerStore.highlightEntities([entity.id])
                                if let firstBlock = entity.blockRefs.first {
                                    readerStore.scrollToBlock(firstBlock, centered: true)
                                }
                            } label: {
                                Text(entity.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.gray600)
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(palette.gray50))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(palette.gray200))
                            }
                            .buttonStyle(.plain)
                            .help(entity.definitionZh.isEmpty ? entity.category : entity.definitionZh)
                        }
                    }
                    .padding(.top, 7)
                }
            }
        }
        .padding(18)
    }

    private func summarySection<Content: View>(title: String, systemImage: String?, featured: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image.ic(systemImage).font(.system(size: 10))
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(palette.accent)

            content()
        }
        .padding(.top, 13)
        .overlay(alignment: .top) { Rectangle().fill(palette.gray100).frame(height: 1) }
        .modifier(FeaturedModifier(palette: palette, featured: featured))
    }
}

private struct FeaturedModifier: ViewModifier {
    let palette: Palette
    let featured: Bool

    func body(content: Content) -> some View {
        if featured {
            content
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 9).fill(palette.accentFaint))
                .padding(.top, 1)
        } else {
            content
        }
    }
}

extension Text {
    func summaryBody(palette: Palette) -> some View {
        self
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(palette.gray600)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Simple wrapping chip layout.
struct FlowChips<Content: View>: View {
    let maxWidth: Int
    @ViewBuilder let content: () -> Content

    init(maxWidth: Int = Int.max, @ViewBuilder content: @escaping () -> Content) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), alignment: .leading)], alignment: .leading, spacing: 4) {
            content()
        }
    }
}
