import SwiftUI

#if os(macOS)
import AppKit

/// AppKit controls the preview frame precisely; the card's leading top corner
/// follows the pointer, including when dragging an entire selection.
private struct WorkspaceDragSource: NSViewRepresentable {
    let kind: WorkspaceDragKind
    let ids: [String]
    let title: String
    let subtitle: String
    let enabled: Bool
    let onClick: () -> Void
    let dark: Bool
    let accent: NSColor

    func makeNSView(context: Context) -> DragAnchorView { DragAnchorView() }
    func updateNSView(_ view: DragAnchorView, context: Context) {
        view.configuration = self
    }

    final class DragAnchorView: NSView, NSDraggingSource {
        var configuration: WorkspaceDragSource?
        private var start: NSPoint?
        private var dragging = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let configuration, configuration.enabled else { return nil }
            let local = convert(point, from: superview)
            guard bounds.contains(local) else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start, let configuration, configuration.enabled else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) >= 5,
                  let data = try? JSONEncoder().encode(configuration.ids), !configuration.ids.isEmpty else { return }
            self.start = nil
            let writer = NSPasteboardItem()
            writer.setData(data, forType: NSPasteboard.PasteboardType(configuration.kind.type.identifier))
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = configuration.preview()
            item.setDraggingFrame(NSRect(x: point.x, y: point.y - image.size.height, width: image.size.width, height: image.size.height), contents: image)
            dragging = true
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = false
            session.draggingFormation = .none
        }

        override func mouseUp(with event: NSEvent) {
            if !dragging, start != nil { configuration?.onClick() }
            start = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .copy : []
        }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragging = false
            start = nil
        }
    }

    private func preview() -> NSImage {
        let size = NSSize(width: 320, height: 128)
        return NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: CornerRadius.card, yRadius: CornerRadius.card)
            (dark ? NSColor(calibratedWhite: 0.16, alpha: 0.94) : NSColor(calibratedWhite: 0.98, alpha: 0.94)).setFill()
            shape.fill()
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let ink = dark ? NSColor.white : NSColor.black
            (title as NSString).draw(in: NSRect(x: 16, y: 61, width: 288, height: 51), withAttributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: ink, .paragraphStyle: style
            ])
            (subtitle as NSString).draw(in: NSRect(x: 16, y: 37, width: 288, height: 18), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink.withAlphaComponent(0.6), .paragraphStyle: style
            ])
            let label = ids.count > 1 ? "\(ids.count) 个条目 · 拖到分组" : "拖到分组"
            (label as NSString).draw(at: NSPoint(x: 16, y: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: accent])
            return true
        }
    }
}

extension View {
    func workspaceDraggable(kind: WorkspaceDragKind, ids: [String], title: String, subtitle: String, enabled: Bool, palette: Palette, dragHeight: CGFloat? = nil, onClick: @escaping () -> Void = {}) -> some View {
        overlay(alignment: .topLeading) {
            WorkspaceDragSource(kind: kind, ids: ids, title: title, subtitle: subtitle, enabled: enabled, onClick: onClick, dark: palette.dark, accent: NSColor(palette.accent))
                .frame(height: dragHeight).allowsHitTesting(enabled)
        }
    }
}
#endif
