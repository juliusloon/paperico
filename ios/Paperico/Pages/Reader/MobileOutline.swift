import SwiftUI

/// Mirrors reader/MobileOutline.tsx — full-screen logic outline for the compact reader.
struct MobileOutline: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore

    var onNavigate: (String) -> Void
    var onEntityChat: (MethodEntity, String) -> Void

    private var blocks: [Block] { readerStore.paper?.blocks ?? [] }

    var body: some View {
        Group {
            if blocks.isEmpty {
                VStack {
                    Text("论文内容尚未准备好,逻辑目录会在解析完成后出现。")
                        .font(.system(size: 12))
                        .lineSpacing(5)
                        .foregroundStyle(palette.gray400)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OUTLINE")
                            .font(.mono(9, weight: .bold))
                            .kerning(1.7)
                            .foregroundStyle(palette.accent)
                        Text("论文逻辑目录")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(palette.gray800)
                        Text("\(blocks.count) 个节点 · 点击节点跳转正文,点击标签加入对话")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.gray400)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                                let entityMap = Dictionary(uniqueKeysWithValues: (readerStore.paper?.entities ?? []).map { ($0.id, $0) })
                                let entities = block.entityRefs.compactMap { entityMap[$0] }
                                OutlineNode(
                                    block: block,
                                    entities: entities,
                                    index: index,
                                    active: readerStore.activeBlockId == block.id,
                                    leading: true,
                                    onClick: { handleNavigate(block.id) },
                                    onEntityClick: { entity in handleEntityChat(entity, blockId: block.id) }
                                )
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .stroke(palette.gray300.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                        .frame(width: 1)
                                        .padding(.leading, 8)
                                        .opacity(0.6)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 42)
                    }
                }
                .background(palette.gray0)
            }
        }
    }

    private func handleNavigate(_ blockId: String) {
        readerStore.setActiveBlock(blockId)
        onNavigate(blockId)
    }

    private func handleEntityChat(_ entity: MethodEntity, blockId: String) {
        onEntityChat(entity, blockId)
    }
}
