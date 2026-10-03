import AppKit
import SwiftUI

/// Exercise the actual SwiftUI renderer in a hidden host, with no library writes
/// or network requests. Unit tests alone would not catch the old view subscript.
@main
enum MarkdownRenderingSmoke {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let table = """
        | 方法 | 优势 | 局限 |
        | --- | --- | --- |
        | ACA | 感知活性悬崖 | 需要标签 |
        | GNN |
        | ECFP | 指纹 |
        | PNA | 聚合 | 依赖训练 |
        | GCN | 卷积 | 平滑假设 |
        | GAT | 注意力 | 成本 |
        """
        let host = NSHostingView(rootView: MarkdownText(text: ""))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        var renders = 0
        for width in [220.0, 330.0, 480.0] {
            // Replay every partial output, including changing/ragged table rows.
            for end in table.indices {
                host.rootView = MarkdownText(text: String(table[...end]))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 1000)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                precondition(host.fittingSize.height.isFinite)
                renders += 1
            }
        }
        // Materialize all cells of the completed table, including later rows.
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        } else {
            fatalError("Unable to render the Markdown host")
        }
        print("Markdown rendering passed: \(renders) streamed snapshots at 3 panel widths.")
    }
}
