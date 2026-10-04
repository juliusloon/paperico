import SwiftUI

/// Papers and methods use the same inline editor and glass actions.
struct WorkspaceItemEditor: View {
    @Binding var name: String
    var namePrompt: String
    var detail: Binding<String>?
    var detailPrompt = "说明"
    var busy = false
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(namePrompt, text: $name, axis: .vertical)
                .font(.system(size: 16.5, weight: .semibold)).textFieldStyle(.plain)
                .lineLimit(1...5).focused($nameFocused)
                .padding(9).liquidInset(cornerRadius: CornerRadius.inset)
                .accessibilityLabel(namePrompt)
                .onSubmit { save() }
            if let detail {
                TextField(detailPrompt, text: detail, axis: .vertical)
                    .font(.system(size: 14)).textFieldStyle(.plain).lineLimit(3...10)
                    .padding(9).liquidInset(cornerRadius: CornerRadius.inset)
                    .accessibilityLabel(detailPrompt)
                    .onSubmit { save() }
            }
            HStack(spacing: 8) {
                ToolbarButton(title: "保存", icon: Ic.check, kind: .primary, busy: busy, disabled: !valid) { save() }
                ToolbarButton(title: "取消", icon: Ic.close, disabled: busy, action: onCancel)
            }
        }
        .disabled(busy)
        .onAppear { nameFocused = true }
        .onExitCommand { if !busy { onCancel() } }
    }

    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func save() { if valid && !busy { onSave() } }
}
