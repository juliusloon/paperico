import SwiftUI
import AppKit

/// A narrow bridge to the text system: IME-safe Return, Shift-Return, focus, and history recall.
struct MessageInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    var placeholder = "向论文提问…"
    var onSubmit: () -> Void
    var onCancel: (() -> Void)? = nil
    var onRecall: (() -> Void)? = nil
    var fontSize: CGFloat = 12.5
    var fontWeight: NSFont.Weight = .regular
    var alignment: NSTextAlignment = .left
    var contentInset = NSSize(width: 2, height: 7)
    var formatsMarkdown = false
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        let view = InputTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 32))
        view.minSize = NSSize(width: 0, height: 32)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        view.isRichText = false; view.drawsBackground = false; view.isEditable = true
        view.isSelectable = true; view.allowsUndo = true
        view.textContainerInset = contentInset
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.delegate = context.coordinator
        scroll.documentView = view
        context.coordinator.view = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator; c.parent = self
        guard let view = c.view else { return }
        view.font = .systemFont(ofSize: fontSize, weight: fontWeight)
        view.alignment = alignment
        view.textContainerInset = contentInset
        view.formatsMarkdown = formatsMarkdown
        view.textColor = NSColor(palette.gray800); view.insertionPointColor = NSColor(palette.accent)
        view.setAccessibilityLabel(placeholder)
        view.placeholder = placeholder; view.placeholderColor = NSColor(palette.gray400)
        view.onSubmit = onSubmit; view.onCancel = onCancel; view.onRecall = onRecall
        if view.string != text && !view.hasMarkedText() {
            let selected = view.selectedRange()
            view.string = text
            view.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
            c.measure()
        }
        if focused && view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view] in
                guard let view, c.parent.focused else { return }
                view.window?.makeFirstResponder(view)
            }
        }
        view.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageInput
        weak var view: InputTextView?
        init(_ parent: MessageInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string; view.needsDisplay = true; measure()
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }
        func measure() {
            guard let view, let layout = view.layoutManager, let container = view.textContainer else { return }
            layout.ensureLayout(for: container)
            let height = min(110, max(32, ceil(layout.usedRect(for: container).height + 14)))
            DispatchQueue.main.async { [weak self] in if let self, self.parent.height != height { self.parent.height = height } }
        }
    }
}

@MainActor final class InputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRecall: (() -> Void)?
    var placeholder = ""
    var placeholderColor = NSColor.placeholderTextColor
    var formatsMarkdown = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if formatsMarkdown, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .control, .option]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let marker = ["b": "**", "i": "*", "h": "=="][key] {
            let range = selectedRange()
            let selected = (string as NSString).substring(with: range)
            insertText(marker + selected + marker, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + marker.utf16.count, length: range.length))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12.5), .foregroundColor: placeholderColor])
        }
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 36 || event.keyCode == 76 {
                if !event.modifierFlags.contains(.shift) { onSubmit?(); return }
            }
            if event.keyCode == 53, let onCancel { onCancel(); return }
            if event.keyCode == 126 && string.isEmpty, let onRecall { onRecall(); return }
        }
        super.keyDown(with: event)
    }
}
