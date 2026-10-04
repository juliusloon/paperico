import SwiftUI
import UniformTypeIdentifiers

/// Shared editor for paper projects and method groups.
struct WorkspaceGroupEditor: View {
    @Binding var name: String
    var creating = false
    var busy = false
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("分组名称", text: $name)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 36)
                .liquidInset(cornerRadius: CornerRadius.inset)
                .focused($focused).onSubmit { if valid && !busy { onSave() } }
            HStack(spacing: 6) {
                Button(creating ? "创建" : "保存", action: onSave)
                    .buttonStyle(LiquidActionButtonStyle(prominent: true))
                    .disabled(!valid || busy)
                Button("取消", action: onCancel)
                    .buttonStyle(LiquidActionButtonStyle()).disabled(busy)
                Spacer(minLength: 0)
            }.font(.system(size: 12, weight: .medium))
        }
        .padding(10).liquidInset(tint: nil)
        .onAppear { focused = true }
        .onExitCommand { if !busy { onCancel() } }
    }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct WorkspaceGroupRow: View {
    @Environment(\.palette) private var palette
    let name: String
    let count: Int
    let active: Bool
    var color: Color?
    var targeted = false
    let onSelect: () -> Void
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    if let color { Circle().fill(color).frame(width: 7, height: 7) }
                    Text(name).font(.system(size: 14)).lineLimit(1)
                        .foregroundStyle(active || targeted ? palette.accent : palette.gray700)
                    Spacer(minLength: 0)
                    if targeted {
                        Image(systemName: "plus.circle.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.accent)
                            .accessibilityLabel("移入此分组")
                    } else {
                        Text("\(count)").font(.system(size: 10)).foregroundStyle(palette.gray500.opacity(0.6))
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).frame(minHeight: 42)
        .background {
            if targeted { GlassSurface(shape: RoundedRectangle(cornerRadius: CornerRadius.inset), tint: palette.accentSoft, interactive: true) }
            else { RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).fill(active ? palette.accentSoft : .clear) }
        }
        .overlay { RoundedRectangle(cornerRadius: CornerRadius.inset).stroke(targeted ? palette.accent.opacity(0.7) : .clear) }
        .contextMenu {
            if let onRename { Button("重命名分组", action: onRename) }
            if let onDelete { Button("删除分组", role: .destructive, action: onDelete) }
        }
    }
}
