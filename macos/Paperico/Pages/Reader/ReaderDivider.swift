import AppKit
import SwiftUI

/// Track the pointer in screen coordinates so moving the divider cannot change
/// the origin of the next drag event. AppKit owns only this small input surface.
struct ReaderDivider: NSViewRepresentable {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    let label: String
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> DividerView { DividerView() }

    func updateNSView(_ view: DividerView, context: Context) {
        view.axis = axis
        view.onChange = onChange
        view.onEnd = onEnd
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(label)
        view.window?.invalidateCursorRects(for: view)
    }

    final class DividerView: NSControl {
        // The workspace can move from blank background, but this input surface owns
        // its complete drag sequence, including the first click before any motion.
        override var mouseDownCanMoveWindow: Bool { false }
        var axis: Axis = .horizontal
        var onChange: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var origin: NSPoint?
        private var hovered = false
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            guard hovered || origin != nil else { return }
            NSColor.tertiaryLabelColor.setFill()
            let size = axis == .horizontal ? CGSize(width: 2, height: 34) : CGSize(width: 32, height: 2)
            let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
        override func mouseDown(with event: NSEvent) { origin = screenPoint(event); needsDisplay = true }
        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            let current = screenPoint(event)
            onChange?(axis == .horizontal ? current.x - origin.x : origin.y - current.y)
        }
        override func mouseUp(with event: NSEvent) {
            guard origin != nil else { return }
            mouseDragged(with: event)
            origin = nil
            needsDisplay = true
            onEnd?()
        }
        private func screenPoint(_ event: NSEvent) -> NSPoint {
            window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        }
    }
}
