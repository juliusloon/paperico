import SwiftUI

/// Papers and methods use the same inline editor and glass actions.
struct WorkspaceItemEditor: View {
    @Binding var name: String
    var namePrompt: String
    var detail: Binding<String>?
    var detailPrompt = "说明"
    var busy = false
    var nameFontSize: CGFloat = 16.5
    var nameFontWeight: Font.Weight = .semibold
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InlineNameEditor(name: $name, prompt: namePrompt, fontSize: nameFontSize,
                             fontWeight: nameFontWeight, lineLimit: 1...5, confirmTitle: "保存", busy: busy,
                             onSave: save, onCancel: onCancel)
            if let detail {
                TextField(detailPrompt, text: detail, axis: .vertical)
                    .font(.system(size: 14)).textFieldStyle(.plain).lineLimit(3...10)
                    .padding(9).liquidInset(cornerRadius: CornerRadius.inset)
                    .accessibilityLabel(detailPrompt)
                    .onSubmit { save() }
            }
        }
        .disabled(busy)
        .onExitCommand { if !busy { onCancel() } }
    }

    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func save() { if valid && !busy { onSave() } }
}
