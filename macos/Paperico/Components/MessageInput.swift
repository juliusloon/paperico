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
        view.formatBaseFont = .systemFont(ofSize: fontSize, weight: fontWeight)
        view.alignment = alignment
        view.textContainerInset = contentInset
        view.formatsMarkdown = formatsMarkdown
        view.isRichText = formatsMarkdown
        view.formatHighlightColor = NSColor(palette.accentSoft)
        view.updateFormatMonitor()
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
        view.applyNoteFormatting()
        view.needsDisplay = true
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? InputTextView)?.removeFormatMonitor()
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageInput
        weak var view: InputTextView?
        init(_ parent: MessageInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            parent.text = view.string; view.applyNoteFormatting(); view.needsDisplay = true; measure()
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
    var formatHighlightColor = NSColor.selectedTextBackgroundColor
    var formatBaseFont = NSFont.systemFont(ofSize: 14)
    private var styling = false
    private var formatMonitor: Any?
    override var mouseDownCanMoveWindow: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if format(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    func updateFormatMonitor() {
        if !formatsMarkdown { removeFormatMonitor(); return }
        guard formatMonitor == nil else { return }
        // Cmd-H is normally intercepted by the app's Hide menu before the
        // responder chain. Consume formatting only while this note owns focus.
        formatMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.firstResponder === self else { return event }
            return self.format(event) ? nil : event
        }
    }
    func removeFormatMonitor() {
        if let formatMonitor { NSEvent.removeMonitor(formatMonitor) }
        formatMonitor = nil
    }
    private func format(_ event: NSEvent) -> Bool {
        if formatsMarkdown, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .control, .option]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           let marker = ["b": "**", "i": "*", "h": "=="][key] {
            let result = ReaderNoteFormatting.toggle(string, selection: selectedRange(), marker: marker)
            insertText(result.value, replacementRange: NSRange(location: 0, length: (string as NSString).length))
            setSelectedRange(result.selection)
            return true
        }
        return false
    }
    func applyNoteFormatting() {
        guard formatsMarkdown, !hasMarkedText(), !styling, let storage = textStorage else { return }
        let font = formatBaseFont
        styling = true
        defer { styling = false }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttributes([.font:font,.foregroundColor:textColor ?? NSColor.labelColor],range:whole)
        storage.removeAttribute(.backgroundColor,range:whole)
        let code = (try? NSRegularExpression(pattern: #"`[^`\n]*`"#))?.matches(in: string, range: whole).map(\.range) ?? []
        let formats: [(String,NSFontTraitMask,Bool)] = [
            (#"\*\*(.+?)\*\*"#,.boldFontMask,false),
            (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#,.italicFontMask,false),
            (#"\*\*\*(.+?)\*\*\*"#,[.boldFontMask,.italicFontMask],false),
            (#"==(.+?)=="#,[],true)
        ]
        for (pattern,traits,highlight) in formats {
            guard let regex = try? NSRegularExpression(pattern:pattern) else { continue }
            for match in regex.matches(in:string,range:whole) where !code.contains(where:{ NSIntersectionRange($0,match.range).length > 0 }) {
                let range = match.range(at:1)
                if highlight { storage.addAttribute(.backgroundColor,value:formatHighlightColor,range:range) }
                else {
                    storage.enumerateAttribute(.font,in:range) { current,subrange,_ in
                        storage.addAttribute(.font,value:NSFontManager.shared.convert(current as? NSFont ?? font,toHaveTrait:traits),range:subrange)
                    }
                }
            }
        }
        storage.endEditing()
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
