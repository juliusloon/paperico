import SwiftUI

/// Margin outline node (mirrors reader/OutlineNode.tsx, incl. getOutlineLevel).
func getOutlineLevel(for block: Block) -> Int {
    guard block.kind != "section_heading" else {
        let title = (block.textOriginal.isEmpty ? block.sectionTitle : block.textOriginal)
            .replacingOccurrences(of: "^■\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.range(of: "^([A-Z][A-Z\\s/&-]{3,})$", options: .regularExpression) != nil || block.order == 2 {
            return 0
        }
        return 1
    }
    return 2
}

struct OutlineNode: View {
    @Environment(\.palette) private var palette

    let block: Block
    let entities: [MethodEntity]
    let index: Int
    let active: Bool
    let leading: Bool          // mobile outline variant (left aligned)
    let onClick: () -> Void
    let onEntityClick: (MethodEntity) -> Void

    private var level: Int { getOutlineLevel(for: block) }
    private var page: String? { block.pageIdx.map { "P\($0 + 1)" } }

    private var label: String {
        if block.kind == "section_heading" { return level == 0 ? "SECTION" : "SUBSECTION" }
        if !block.roleInNarrative.isEmpty { return block.roleInNarrative }
        return "NODE \(String(format: "%02d", index + 1))"
    }

    private var title: String {
        if block.kind == "section_heading" {
            return block.textZh.isEmpty ? (block.textOriginal.isEmpty ? block.sectionTitle : block.textOriginal) : block.textZh
        }
        if !block.oneLiner.isEmpty { return block.oneLiner }
        return block.textZh.isEmpty ? block.textOriginal : block.textZh
    }

    var body: some View {
        Button(action: onClick) {
            VStack(alignment: leading ? .leading : .trailing, spacing: 5) {
                Text(label + (page.map { " · \($0)" } ?? ""))
                    .font(.mono(10, weight: .semibold))
                    .kerning(0.7)
                    .lineLimit(2)
                    .multilineTextAlignment(leading ? .leading : .trailing)
                    .foregroundStyle(palette.gray400)
                    .fixedSize(horizontal: false, vertical: true)

                Text(title)
                    .font(.system(size: titleSize, weight: titleWeight))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(leading ? .leading : .trailing)
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)

                if !entities.isEmpty {
                    HStack(spacing: 4) {
                        if !leading { Spacer(minLength: 0) }
                        ForEach(entities) { entity in
                            Button {
                                onEntityClick(entity)
                            } label: {
                                Text(entity.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.accentSoft))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.accent.opacity(0.22)))
                            }
                            .buttonStyle(.plain)
                            .help("将 \(entity.name) 加入论文对话")
                        }
                        if leading { Spacer(minLength: 0) }
                    }
                }
            }
            .padding(.leading, leading ? CGFloat(26 + level * 14) : CGFloat(8 + level * 14))
            .padding(.trailing, leading ? 10 : 19)
            .padding(.top, 7)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
            .background(RoundedRectangle(cornerRadius: 8).fill(active ? palette.accentFaint : Color.clear))
            .overlay(alignment: leading ? .leading : .trailing) {
                Circle()
                    .fill(active ? palette.accent : (block.kind == "section_heading" ? palette.gray800 : palette.gray300))
                    .frame(width: active ? 9 : (level == 0 ? 9 : 7), height: active ? 9 : (level == 0 ? 9 : 7))
                    .background(Circle().fill(palette.gray0))
                    .overlay(Circle().stroke(palette.gray300))
                    .offset(x: leading ? -10 : 10)
                    .opacity(leading ? 1 : 1)
                    .shadow(color: active ? palette.accentSoft : .clear, radius: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var titleSize: CGFloat {
        switch level {
        case 0: return 15.5
        case 1: return 14.5
        default: return 14
        }
    }

    private var titleWeight: Font.Weight {
        switch level {
        case 0: return .semibold
        case 1: return .medium
        default: return .regular
        }
    }

    private var titleColor: Color {
        if active { return palette.accent }
        switch level {
        case 0: return palette.gray900
        case 1: return palette.gray800
        default: return palette.gray600
        }
    }
}
