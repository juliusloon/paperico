import AppKit
import SwiftUI

/// TextKit lays out each native glass button as a text attachment, keeping
/// citations at their original location and wrapping them with the paragraph.
struct CitationInlineText: NSViewRepresentable {
    let markdown: String
    let fontSize: CGFloat
    let color: Color
    let validIds: Set<String>
    let onCitation: (String) -> Void
    var baseWeight: NSFont.Weight = .regular
    var mathSplitter = true
    @Environment(\.palette) private var palette
    @Environment(\.glassOpacity) private var glassOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> CitationSurface { CitationSurface() }
    func updateNSView(_ view: CitationSurface, context: Context) { view.configure(self) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CitationSurface, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.measure(width: width))
    }

    final class CitationSurface: NSView {
        private let textView = CitationTextView()
        private var signature = ""
        private var buttons: [(NSRange, NSHostingView<AnyView>)] = []
        private var onCitation: ((String) -> Void)?
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override init(frame: NSRect) {
            super.init(frame: frame)
            textView.drawsBackground = false
            textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
            textView.textContainerInset = .zero
            textView.textContainer?.lineFragmentPadding = 0
            textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            addSubview(textView)
        }
        required init?(coder: NSCoder) { nil }

        fileprivate func configure(_ parent: CitationInlineText) {
            onCitation = parent.onCitation
            let key = "\(parent.markdown)|\(parent.fontSize)|\(parent.baseWeight.rawValue)|\(parent.mathSplitter)|\(parent.validIds.sorted())|\(NSColor(parent.color))|\(NSColor(parent.palette.accent))|\(parent.palette.dark)|\(parent.glassOpacity)|\(parent.reduceTransparency)"
            guard signature != key else { return }
            signature = key
            buttons.forEach { $0.1.removeFromSuperview() }; buttons.removeAll()
            textView.citations = [:]
            let source = parent.mathSplitter ? InlineMathSplitter.inlineMathToCode(parent.markdown) : parent.markdown
            let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            let text = parsed.map { NSMutableAttributedString(attributedString: NSAttributedString($0)) } ?? NSMutableAttributedString(string: parent.markdown)
            let font = NSFont.systemFont(ofSize: parent.fontSize, weight: parent.baseWeight)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
            text.addAttributes([.font:font,.foregroundColor:NSColor(parent.color),.paragraphStyle:paragraph],
                               range: NSRange(location: 0, length: text.length))
            text.enumerateAttribute(.inlinePresentationIntent, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                let intent = InlinePresentationIntent(rawValue: (value as? NSNumber)?.uintValue ?? 0)
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: traits), range: range) }
                if intent.contains(.code) { text.addAttribute(.backgroundColor, value: NSColor(parent.palette.gray100), range: range) }
            }
            for match in ChatCitation.matches(in: text.string, validIds: parent.validIds).reversed() {
                let intent = InlinePresentationIntent(rawValue: (text.attribute(.inlinePresentationIntent, at: match.range.location, effectiveRange: nil) as? NSNumber)?.uintValue ?? 0)
                guard !intent.contains(.code), text.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
                let label = "证据 " + (match.blockId.split(separator: "-").last.map(String.init) ?? match.blockId)
                let width = (label as NSString).size(withAttributes: [.font:NSFont.systemFont(ofSize: 10)]).width + 33
                let attachment = NSTextAttachment()
                attachment.attachmentCell = CitationCell(size: NSSize(width: width, height: 24))
                textView.citations[ObjectIdentifier(attachment)] = match.blockId
                text.replaceCharacters(in: match.range, with: NSAttributedString(attachment: attachment))
            }
            textView.textStorage?.setAttributedString(text)
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let attachment = value as? NSTextAttachment, let id = textView.citations[ObjectIdentifier(attachment)] else { return }
                let button = Button { [weak self] in self?.onCitation?(id) } label: {
                    Label("证据 " + (id.split(separator: "-").last.map(String.init) ?? id), systemImage: "arrow.up.right")
                        .font(.system(size: 10)).foregroundStyle(parent.palette.accent)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .liquidInset(cornerRadius: CornerRadius.chip, tint: parent.palette.accentFaint)
                }.buttonStyle(.plain).noFocusRing().accessibilityLabel("跳转到证据 " + id)
                let host = NSHostingView(rootView: AnyView(button.environment(\.palette, parent.palette)
                    .environment(\.glassOpacity,parent.glassOpacity)
                    .environment(\.colorScheme,parent.palette.dark ? .dark : .light)))
                addSubview(host); buttons.append((range,host))
            }
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
        fileprivate func measure(width: CGFloat) -> CGFloat {
            textView.frame = CGRect(x: 0, y: 0, width: width, height: max(1,bounds.height))
            textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            guard let manager = textView.layoutManager, let container = textView.textContainer else { return 1 }
            manager.ensureLayout(for: container)
            return ceil(manager.usedRect(for: container).height) + 1
        }
        override func layout() {
            super.layout()
            _ = measure(width: max(1,bounds.width))
            textView.frame = bounds
            guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
            for (range,host) in buttons {
                let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                host.frame = manager.boundingRect(forGlyphRange: glyphs, in: container)
            }
        }
    }
}

private final class CitationCell: NSTextAttachmentCell {
    let size: NSSize
    init(size: NSSize) { self.size = size; super.init(textCell: "") }
    required init(coder: NSCoder) { size = coder.decodeSize(forKey: "citationSize"); super.init(coder: coder) }
    override func encode(with coder: NSCoder) { super.encode(with: coder); coder.encode(size, forKey: "citationSize") }
    override func cellSize() -> NSSize { size }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -5) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
}

private final class CitationTextView: NSTextView {
    var citations: [ObjectIdentifier: String] = [:]
    override var mouseDownCanMoveWindow: Bool { false }
    override func copy(_ sender: Any?) {
        guard let storage = textStorage, selectedRange().length > 0 else { return }
        let selection = storage.attributedSubstring(from: selectedRange())
        var replacements: [(NSRange,String)] = []
        selection.enumerateAttribute(.attachment, in: NSRange(location: 0, length: selection.length)) { value, range, _ in
            if let attachment = value as? NSTextAttachment, let id = citations[ObjectIdentifier(attachment)] { replacements.append((range,"[" + id + "]")) }
        }
        let copy = NSMutableString(string: selection.string)
        for (range,id) in replacements.reversed() { copy.replaceCharacters(in: range, with: id) }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copy as String, forType: .string)
    }
}
