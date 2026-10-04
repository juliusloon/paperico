import AppKit
import SwiftUI

/// The web document supplies an anchor and reserves space; editing uses the
/// same system glass and controls as WorkspaceItemEditor, rather than CSS blur.
struct ReaderAnnotationEditor: View {
    let field: String
    let value: String
    let size: CGSize
    let onInput: (String) -> Void
    let onFinish: (String, Bool) -> Void
    let onResize: (CGSize) -> Void
    @State private var text = ""
    @State private var focused = true
    @State private var measuredHeight: CGFloat = 32
    @State private var resizeOrigin: CGSize?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MessageInput(text: $text, height: $measuredHeight, focused: $focused,
                         placeholder: field == "note" ? "节点笔记" : "逻辑链内容",
                         onSubmit: save, onCancel: { onFinish(text, false) },
                         fontSize: field == "note" ? 14 : 16.5,
                         fontWeight: field == "note" ? .regular : .semibold,
                         alignment: .right, contentInset: .zero, formatsMarkdown: field == "note")
                .padding(9)
                .frame(width: size.width, height: size.height)
                .liquidInset(cornerRadius: CornerRadius.inset, bordered: false)
                .overlay(alignment: .bottomTrailing) {
                    AnnotationResizeCorner { delta in
                        if resizeOrigin == nil { resizeOrigin = size }
                        guard let resizeOrigin else { return }
                        onResize(CGSize(width: resizeOrigin.width + delta.width,
                                        height: resizeOrigin.height + delta.height))
                    } onEnd: { resizeOrigin = nil }
                    .frame(width: 16, height: 16)
                }
            HStack(spacing: 8) {
                ToolbarButton(title: "保存", icon: Ic.check, kind: .primary, disabled: !valid, action: save)
                ToolbarButton(title: "取消", icon: Ic.close) { onFinish(text, false) }
            }.frame(height: 38)
        }
        .frame(width: size.width, alignment: .leading)
        .onAppear { text = value; focused = true }
        .onChange(of: text) { _, value in onInput(value) }
    }

    private var valid: Bool { field == "note" || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func save() { if valid { onFinish(text, true) } }
}

/// Invisible corner: owns the mouse sequence so resizing never moves a window.
private struct AnnotationResizeCorner: NSViewRepresentable {
    let onChange: (CGSize) -> Void
    let onEnd: () -> Void
    func makeNSView(context: Context) -> CornerView { CornerView() }
    func updateNSView(_ view: CornerView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class CornerView: NSControl {
        var onChange: ((CGSize) -> Void)?
        var onEnd: (() -> Void)?
        private var origin: NSPoint?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: [.inward, .outward])) }
        override func mouseDown(with event: NSEvent) { origin = point(event) }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let current = point(event)
            onChange?(CGSize(width: current.x - origin.x, height: origin.y - current.y))
        }
        override func mouseUp(with event: NSEvent) {
            guard origin != nil else { return }
            mouseDragged(with: event)
            origin = nil
            onEnd?()
        }
        private func point(_ event: NSEvent) -> NSPoint {
            window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        }
    }
}
