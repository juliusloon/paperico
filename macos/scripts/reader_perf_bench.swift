// Reading-page render benchmark — runs the app's REAL source file (MarkdownText /
// PaperMarkdown / Models) against REAL payloads from GET /api/papers/{id}.
//
// Why this exists: on this machine Swift cannot expand macros (@Observable / @State),
// so the whole app cannot be compiled here. The dominant costs of the reading page
// are pure functions of the payload, so they are compiled directly and measured.
//
// Build & run:
//   cd macos && ./scripts/run_reader_bench.sh /tmp/detail_9f73f3144329.json
//
// Or manually:
//   xcrun --sdk macosx swiftc -O \
//     Paperico/Support/PaperMarkdown.swift Paperico/Support/ReaderPerf.swift \
//     Paperico/Components/MarkdownText.swift Paperico/App/Theme.swift \
//     Paperico/Models/Models.swift scripts/reader_perf_bench.swift -o /tmp/readerbench

import Foundation
import SwiftUI

// MARK: - constants mirroring the app defaults

enum BenchConfig {
    /// ReaderStore.fontSize default.
    static let readingFontSize: CGFloat = 18
    /// Palette.defaultLight gray100 — the inline-code background that goes into
    /// the AttributedString cache key.
    static let gray100 = Color(hex: "#eef0f3")!
    /// Default bilingual mode: both original and translation are rendered.
    /// Conservative estimate of rows in the viewport (LazyVStack only builds these).
    static let visibleRows = 15
}

// MARK: - exit path decoding (mirrors ApiClient.decoder)

func loadDetail(_ path: String) throws -> PaperDetail {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(PaperDetail.self, from: data)
}

// MARK: - faithful reproduction of one body evaluation

/// Renders the markdown parts of a block exactly the way `MarkdownText` does.
/// - parameter cached: false = 修改前的行为(每次都解析);true = 走 PaperMarkdown 缓存。
func renderMarkdown(_ text: String, fontSize: CGFloat, cached: Bool) {
    let blocks = cached
        ? PaperMarkdown.blocks(for: text)
        : PaperMarkdown.parseBlocksUncached(text)
    for part in blocks {
        switch part {
        case .heading(_, let t):
            attributed(t, fontSize: fontSize, cached: cached, useMathSplitter: false)
        case .paragraph(let p):
            attributed(p, fontSize: fontSize, cached: cached, useMathSplitter: true)
        case .quote(let lines):
            for line in lines { attributed(line, fontSize: fontSize, cached: cached, useMathSplitter: true) }
        case .unordered(let items):
            for item in items { attributed(item, fontSize: fontSize, cached: cached, useMathSplitter: true) }
        case .ordered(let items):
            for item in items { attributed(item, fontSize: fontSize, cached: cached, useMathSplitter: true) }
        case .code, .mathDisplay, .table, .rule:
            break // rendered as plain/table views in both versions
        }
    }
}

func attributed(_ markdown: String, fontSize: CGFloat, cached: Bool, useMathSplitter: Bool) {
    if cached {
        _ = PaperMarkdown.attributedString(
            markdown: markdown,
            fontSize: fontSize,
            codeFont: .mono(fontSize * 0.88),
            codeBackground: BenchConfig.gray100,
            mathSplitter: useMathSplitter
        )
    } else {
        _ = PaperMarkdown.attributedStringUncached(
            markdown: markdown,
            fontSize: fontSize,
            codeFont: .mono(fontSize * 0.88),
            codeBackground: BenchConfig.gray100,
            mathSplitter: useMathSplitter
        )
    }
}

/// `BlockRenderer` + captions, faithful to the bilingual default.
func renderRow(_ block: Block, cached: Bool) {
    switch block.kind {
    case "figure":
        applyCaptions(block, cached: cached)
    case "table":
        if !block.tableHtml.isEmpty {
            if cached { _ = HTMLTableParser.rows(for: block.tableHtml) }
            else { _ = HTMLTableParser.parse(block.tableHtml) }
        }
        applyCaptions(block, cached: cached)
    case "section_heading", "equation":
        break // plain Text views, unchanged by this refactor
    default:
        if !block.textOriginal.isEmpty { renderMarkdown(block.textOriginal, fontSize: BenchConfig.readingFontSize, cached: cached) }
        if !block.textZh.isEmpty { renderMarkdown(block.textZh, fontSize: BenchConfig.readingFontSize - 1, cached: cached) }
    }
}

func applyCaptions(_ block: Block, cached: Bool) {
    if !block.captionOriginal.isEmpty { renderMarkdown(block.captionOriginal, fontSize: 14, cached: cached) }
    let translated = block.captionZh.isEmpty ? block.textZh : block.captionZh
    if !translated.isEmpty { renderMarkdown(translated, fontSize: 14, cached: cached) }
}

/// One full pass over the document.
/// - parameter hoistEntityMap: false = 修改前每个 row 各自重建字典;true = 提升到一次。
func documentPass(_ blocks: [Block], entities: [MethodEntity], cached: Bool, hoistEntityMap: Bool) {
    if hoistEntityMap {
        let entityMap = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        for block in blocks { _ = block.entityRefs.compactMap { entityMap[$0] }; renderRow(block, cached: cached) }
    } else {
        for block in blocks {
            // The old per-row rebuild: O(rows × entities) on every single evaluation.
            let entityMap = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
            _ = block.entityRefs.compactMap { entityMap[$0] }
            renderRow(block, cached: cached)
        }
    }
}

// MARK: - timing helpers

func timeMs(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func bestOf(_ runs: Int, _ body: () -> Void) -> Double {
    var best = Double.greatestFiniteMagnitude
    for _ in 0..<runs { best = min(best, timeMs(body)) }
    return best
}

func row(_ label: String, _ value: String) {
    print(String(format: "  %-46@ %@", label, value))
}

// MARK: - main

@main
struct ReaderPerfBench {
    static func main() {
        let args = CommandLine.arguments.dropFirst()
        let path = args.first ?? "/tmp/detail_9f73f3144329.json"
        guard let detail = try? loadDetail(path) else {
            print("无法读取/解析 \(path)"); exit(1)
        }
        let blocks = detail.blocks
        let entities = detail.entities
        print("""
=========================================================
 Paperico 阅读页渲染基准(真实数据 + 真实源码)
 论文: \(detail.paper.displayTitle)
 block 数 = \(blocks.count)   方法实体数 = \(entities.count)
=========================================================
""")

        // ---- baseline memory + decode cost
        let memStart = ReaderPerf.memoryFootprintMB()
        let rawData = try! Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decodeMs = bestOf(5) { _ = try? decoder.decode(PaperDetail.self, from: rawData) }
        row("JSON 解码(PaperDetail, \(rawData.count / 1024) KB)", String(format: "%.1f ms", decodeMs))

        // ---- entity dictionary rebuild cost (isolated)
        let entityMapOne = timeMs { _ = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) }) }
        row("单次 entity 字典构建", String(format: "%.3f ms", entityMapOne))
        row("修改前: 每 row 各建一次 × \(blocks.count) 行",
            String(format: "%.1f ms/次 body 求值", entityMapOne * Double(blocks.count)))

        // ---- full document pass, before vs after
        let beforeFirst = bestOf(1) { documentPass(blocks, entities: entities, cached: false, hoistEntityMap: false) }
        let beforeRepeat = bestOf(7) { documentPass(blocks, entities: entities, cached: false, hoistEntityMap: false) }

        PaperMarkdown.clearCache()
        let afterWarm = bestOf(1) { documentPass(blocks, entities: entities, cached: true, hoistEntityMap: true) }
        let afterRepeat = bestOf(7) { documentPass(blocks, entities: entities, cached: true, hoistEntityMap: true) }

        print("\n--- 一次全量 body 求值(VStack 时代 = 每帧一次) ---")
        row("修改前 全量 pass", String(format: "%.1f ms (首次 %.1f ms)", beforeRepeat, beforeFirst))
        row("修改后 首次 pass(冷缓存)", String(format: "%.1f ms", afterWarm))
        row("修改后 全量 pass(缓存命中)",
            String(format: "%.1f ms  提速 %.0f×", afterRepeat, beforeRepeat / max(afterRepeat, 0.001)))

        // ---- what a scroll frame costs
        let visible = Array(blocks.prefix(BenchConfig.visibleRows))
        let frameBefore = bestOf(7) { for b in blocks { renderRow(b, cached: false) } }
        let frameAfter = bestOf(7) { for b in visible { renderRow(b, cached: true) } }
        print("\n--- 滚动时单帧成本 ---")
        row("修改前: VStack 全 \(blocks.count) 行重算", String(format: "%.1f ms/帧 → 理论上限 %.0f FPS", frameBefore, 1000 / frameBefore))
        row("修改后: LazyVStack 仅 \(BenchConfig.visibleRows) 行 + 缓存", String(format: "%.2f ms/帧 → 理论上限 %.0f FPS", frameAfter, 1000 / frameAfter))
        row("单帧改善倍数", String(format: "%.0f×", frameBefore / max(frameAfter, 0.001)))

        // ---- memory
        let memEnd = ReaderPerf.memoryFootprintMB()
        print("\n--- 内存 ---")
        row("进程起始 footprint", String(format: "%.1f MB", memStart))
        row("全部 block 缓存预热后", String(format: "%.1f MB (缓存占用 %.1f MB)", memEnd, memEnd - memStart))
        row("每 block 平均缓存占用", String(format: "%.1f KB", (memEnd - memStart) * 1024 / Double(blocks.count)))
        print("=========================================================\n")
    }
}
