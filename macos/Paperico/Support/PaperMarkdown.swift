import Foundation
import SwiftUI

// MARK: - Markdown 解析热点(从 MarkdownText 的 body 里抽出)
//
// 背景:`MarkdownText.body` 原先直接调用 `parseBlocks(_:)`,并在每个段落内
// 用 `AttributedString(markdown:)` 做富文本解析。SwiftUI 的 body 在每次
// 视图失效时都会被重新求值(滚动时每帧都会),于是同一段文本会被反复解析:
// 一篇 180 个 block 的论文,一次全量 body 求值就要跑数百次行解析 + 富文本解析,
// 滚动时每帧重复一遍 —— 这是阅读页卡顿最主要的单项开销。
//
// 这里把纯计算搬到一个可缓存的位置:
//   - `blocks(for:)`        : 行级结构解析结果按原文缓存
//   - `attributedString(...)`: AttributedString 按 (文本 + 字号 + 代码底色) 缓存
// 解析结果只依赖输入,缓存不会改变任何渲染结果。

enum PaperMarkdown {

    enum MarkdownBlock {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(String)
        case quote([String])
        case unordered([String])
        case ordered([String])
        case mathDisplay(String)
        case table([[String]])
        case rule
    }

    // MARK: - 缓存

    private static let blockCache = makeBlockCache()
    private static let attributedCache = makeAttributedCache()

    /// 命中统计,配合 `ReaderPerf` 输出缓存效果;未开启 tracing 时仍然累加(成本极低)。
    static let blockCacheHits = PerfCounter()
    static let blockCacheMisses = PerfCounter()
    static let attributedCacheHits = PerfCounter()
    static let attributedCacheMisses = PerfCounter()
    /// 单次全量 body 求值里"未命中缓存"的累计耗时(纳秒),用来衡量"重算"强度。
    static let uncachedParseNanos = PerfCounter()

    private static func makeBlockCache() -> NSCache<NSString, CachedBlocks> {
        let cache = NSCache<NSString, CachedBlocks>()
        cache.countLimit = 1_500
        return cache
    }

    private static func makeAttributedCache() -> NSCache<AttributedKey, CachedAttributed> {
        let cache = NSCache<AttributedKey, CachedAttributed>()
        cache.countLimit = 2_000
        return cache
    }

    /// 清空所有缓存(论文切换 / 内存告警时调用)。
    static func clearCache() {
        blockCache.removeAllObjects()
        attributedCache.removeAllObjects()
    }

    // MARK: - 行级结构解析

    /// 带缓存的入口。`MarkdownText` 只走这里。
    static func blocks(for source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        let key = source as NSString
        if let hit = blockCache.object(forKey: key) {
            blockCacheHits.add()
            return hit.value
        }
        blockCacheMisses.add()
        let started = DispatchTime.now().uptimeNanoseconds
        let parsed = parseBlocks(source)
        uncachedParseNanos.add(Int(DispatchTime.now().uptimeNanoseconds - started))
        blockCache.setObject(CachedBlocks(parsed), forKey: key)
        return parsed
    }

    /// 不带缓存的原始算法 —— 基准测试用,语义与修改前完全一致。
    static func parseBlocksUncached(_ source: String) -> [MarkdownBlock] {
        parseBlocks(source)
    }

    // MARK: - 富文本解析

    /// 带缓存的 AttributedString 构建。
    /// - parameter codeFont:       代码块 run 的字体(依赖字号)
    /// - parameter codeBackground: 代码块 run 的底色(依赖主题)
    /// - parameter mathSplitter:   是否先做 `$x$` → `` `x` `` 转换(表格/列表/正文需要)
    /// 三者都进缓存 key,主题切换或字号变化都不会拿到旧结果。
    static func attributedString(
        markdown: String,
        fontSize: CGFloat,
        codeFont: Font,
        codeBackground: Color,
        mathSplitter: Bool = false
    ) -> AttributedString? {
        guard !markdown.isEmpty else { return nil }
        let key = AttributedKey(markdown: markdown, fontSize: fontSize, codeBackground: codeBackground, mathSplitter: mathSplitter)
        if let hit = attributedCache.object(forKey: key) {
            attributedCacheHits.add()
            return hit.value
        }
        attributedCacheMisses.add()
        let started = DispatchTime.now().uptimeNanoseconds
        let value = makeAttributedString(
            markdown: markdown,
            fontSize: fontSize,
            codeFont: codeFont,
            codeBackground: codeBackground,
            mathSplitter: mathSplitter
        )
        uncachedParseNanos.add(Int(DispatchTime.now().uptimeNanoseconds - started))
        if let value {
            attributedCache.setObject(CachedAttributed(value), forKey: key)
        }
        return value
    }

    /// 无缓存路径:与修改前完全等价(每次都跑完整解析 + 行内公式正则)。
    static func attributedStringUncached(
        markdown: String,
        fontSize: CGFloat,
        codeFont: Font,
        codeBackground: Color,
        mathSplitter: Bool = false
    ) -> AttributedString? {
        makeAttributedString(
            markdown: markdown,
            fontSize: fontSize,
            codeFont: codeFont,
            codeBackground: codeBackground,
            mathSplitter: mathSplitter
        )
    }

    private static func makeAttributedString(
        markdown: String,
        fontSize: CGFloat,
        codeFont: Font,
        codeBackground: Color,
        mathSplitter: Bool
    ) -> AttributedString? {
        // `$…$` → 行内代码,放在缓存命中之后执行:滚动时不再跑正则。
        let source = mathSplitter ? InlineMathSplitter.inlineMathToCode(markdown) : markdown
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var attributed = try? AttributedString(markdown: source, options: options) else { return nil }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = codeFont
            attributed[run.range].backgroundColor = codeBackground
        }
        return attributed
    }

    // MARK: - 解析实现(与修改前逐行等价)

    static func parseBlocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                index += 1
                var code: [String] = []
                while index < lines.count, !lines[index].trimmed.hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("$$") {
                flushParagraph()
                var math = String(trimmed.dropFirst(2))
                if math.hasSuffix("$$"), math.count >= 2 {
                    math = String(math.dropLast(2))
                    blocks.append(.mathDisplay(math.trimmed))
                    index += 1
                    continue
                }
                index += 1
                while index < lines.count, !lines[index].contains("$$") {
                    math += "\n" + lines[index]
                    index += 1
                }
                if index < lines.count {
                    let tail = lines[index]
                    if let range = tail.range(of: "$$") {
                        math += "\n" + String(tail[..<range.lowerBound])
                    }
                    index += 1
                }
                blocks.append(.mathDisplay(math.trimmed))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingLevel(of: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading, text: String(trimmed.dropFirst(heading)).trimmed))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmed.hasPrefix(">") {
                    quote.append(String(lines[index].trimmed.dropFirst()).trimmed)
                    index += 1
                }
                blocks.append(.quote(quote))
                continue
            }

            if isTableLine(trimmed), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph()
                var rows: [[String]] = [tableCells(trimmed)]
                index += 2 // skip separator
                while index < lines.count, isTableLine(lines[index].trimmed) {
                    rows.append(tableCells(lines[index].trimmed))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, isBullet(lines[index].trimmed) {
                    let item = lines[index].trimmed
                    items.append(String(item.dropFirst(1)).trimmed)
                    index += 1
                }
                blocks.append(.unordered(items))
                continue
            }

            if orderedPrefixLength(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let n = orderedPrefixLength(lines[index].trimmed) {
                    let item = lines[index].trimmed
                    items.append(String(item.dropFirst(n)).trimmed)
                    index += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - 行解析辅助

    static func headingLevel(of line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6, line.count > count else { return nil }
        let after = line[line.index(line.startIndex, offsetBy: count)]
        return after == " " ? count : nil
    }

    static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    static func orderedPrefixLength(_ line: String) -> Int? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let digits = line[..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), dot < line.endIndex else { return nil }
        let after = line.index(after: dot)
        return after < line.endIndex && line[after] == " " ? line.distance(from: line.startIndex, to: after) + 1 : nil
    }

    static func isTableLine(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.contains("|")
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmed
        return isTableLine(trimmed) && trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    static func tableCells(_ line: String) -> [String] {
        var content = line
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - 缓存容器

final class CachedBlocks: Sendable {
    let value: [PaperMarkdown.MarkdownBlock]
    init(_ value: [PaperMarkdown.MarkdownBlock]) { self.value = value }
}

final class CachedAttributed: Sendable {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private final class AttributedKey: NSObject {
    let markdown: String
    let fontSize: CGFloat
    let codeBackgroundKey: String
    let mathSplitter: Bool

    init(markdown: String, fontSize: CGFloat, codeBackground: Color, mathSplitter: Bool) {
        self.markdown = markdown
        self.fontSize = fontSize
        self.codeBackgroundKey = "\(codeBackground)"
        self.mathSplitter = mathSplitter
        super.init()
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(markdown)
        hasher.combine(fontSize)
        hasher.combine(codeBackgroundKey)
        hasher.combine(mathSplitter)
        return hasher.finalize()
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? AttributedKey else { return false }
        return other.markdown == markdown
            && other.fontSize == fontSize
            && other.codeBackgroundKey == codeBackgroundKey
            && other.mathSplitter == mathSplitter
    }
}

extension String {
    /// 由 MarkdownText 迁移而来:解析热点与调用方共用同一个裁剪语义。
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

// MARK: - 行内数学公式转行内代码(保持原实现)

enum InlineMathSplitter {
    /// Rewrites `$x^2$` spans into ``x^2`` so they render as inline code while
    /// keeping everything in one wrapping Text. `$$…$$` display math is handled
    /// earlier as its own block and never reaches here.
    static func inlineMathToCode(_ text: String) -> String {
        guard text.contains("$") else { return text }
        return text.replacingOccurrences(
            of: "(?<!\\$)\\$(?!\\$)([^$\\n]+?)\\$(?!\\$)",
            with: "`$1`",
            options: .regularExpression
        )
    }
}
