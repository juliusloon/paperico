import SwiftUI

/// Compact names keep their display typography, with actions on the trailing edge.
struct InlineNameEditor: View {
    @Binding var name: String
    let prompt: String
    let fontSize: CGFloat
    var fontWeight: Font.Weight = .regular
    var lineLimit: ClosedRange<Int> = 1...2
    var confirmTitle = "确认"
    var busy = false
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField(prompt, text: $name, axis: .vertical)
                .font(.system(size: fontSize, weight: fontWeight)).textFieldStyle(.plain).lineLimit(lineLimit)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .liquidInset(cornerRadius: CornerRadius.inset)
                .focused($focused).accessibilityLabel(prompt).onSubmit(save)
            PillIconButton(title: confirmTitle, icon: Ic.check, active: true, size: 30, action: save)
                .disabled(!valid || busy)
            PillIconButton(title: "取消", icon: Ic.close, size: 30, action: onCancel).disabled(busy)
        }
        .disabled(busy)
        .onAppear { focused = true }
        .onExitCommand { if !busy { onCancel() } }
    }

    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func save() { if valid && !busy { onSave() } }
}
