import CoreGraphics
// usage: click <x> <y> [delay_ms_between_down_up]
let args = CommandLine.arguments
let x = Double(args[1])!, y = Double(args[2])!
let delay = args.count > 3 ? Double(args[3])! / 1000.0 : 0.05
let p = CGPoint(x: x, y: y)
func post(_ type: CGEventType, _ btn: CGMouseButton, _ down: Bool) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: btn)?
        .post(tap: .cghidEventTap)
}
post(.mouseMoved, .left, false)
usleep(30000)
post(.leftMouseDown, .left, true)
usleep(UInt32(delay * 1_000_000))
post(.leftMouseUp, .left, false)
