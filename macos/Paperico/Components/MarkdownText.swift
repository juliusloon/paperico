import SwiftUI

// MARK: - Native Markdown renderer (replaces react-markdown + remark-math + rehype-katex)
//
// SwiftUI has no KaTeX; LaTeX segments ($$…$$ display, $…$ inline) render as
// monospaced math blocks. Everything else (headings, lists, code, blockquotes,
// tables, links, emphasis) renders natively.
//
// 解析部分(`parseBlocks` / `AttributedString(markdown:)`)已经移到
// `Support/PaperMarkdown.swift`,并加上按内容缓存。
// 原因:body 每次求值都会触发解析,而阅读页一次 scroll/一次 activeBlock 变更
// 都会让全部 block 重新求值 —— 原来等于把整篇论文反复重新解析。

struct MarkdownText: View {
    @Environment(\.palette) private var palette

    let text: String
    var fontSize: CGFloat = 14
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(PaperMarkdown.blocks(for: text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: block views

    @ViewBuilder
    private func blockView(_ block: PaperMarkdown.MarkdownBlock) -> some View {
        let baseColor = color ?? palette.gray800
        switch block {
        case .heading(let level, let text):
            // 标题原文直出,不套 `$…$` → 行内代码 的转换(与修改前一致)。
            inlineText(text, mathSplitter: false)
                .font(.reading(fontSize * headingScale(level), weight: .semibold))
                .foregroundStyle(palette.gray900)
                .padding(.top, 2)
        case .paragraph(let text):
            inlineParagraph(text, color: baseColor)
        case .code(let code):
            Text(code)
                .font(.mono(fontSize * 0.88))
                .foregroundStyle(palette.gray800)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.gray100))
                .textSelection(.enabled)
        case .quote(let lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(palette.accent).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        inlineParagraph(line, color: palette.gray600)
                    }
                }
            }
        case .unordered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(palette.gray500)
                        inlineParagraph(item, color: baseColor)
                    }
                }
            }
        case .ordered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(offset + 1).").foregroundStyle(palette.gray500).monospacedDigit()
                        inlineParagraph(item, color: baseColor)
                    }
                }
            }
        case .mathDisplay(let latex):
            Text(latex)
                .font(.mono(fontSize * 0.92))
                .foregroundStyle(palette.gray800)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .horizontalScrollIfAvailable()
        case .table(let rows):
            NativeMarkdownTable(rows: rows, fontSize: fontSize)
        case .rule:
            Rectangle().fill(palette.gray200).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.45
        case 2: return 1.3
        case 3: return 1.16
        case 4: return 1.08
        default: return 1.0
        }
    }

    /// Paragraph with inline math: `$…$` spans are rendered as inline code
    /// (monospaced on the code background) inside the native markdown text so
    /// line wrapping keeps working.
    private func inlineParagraph(_ text: String, color: Color) -> some View {
        // 行内公式转换由 PaperMarkdown 在缓存 miss 时完成,这里不再每次跑正则。
        return inlineText(text, mathSplitter: true)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
    }

    private func inlineText(_ markdown: String, mathSplitter: Bool) -> Text {
        if let attributed = PaperMarkdown.attributedString(
            markdown: markdown,
            fontSize: fontSize,
            codeFont: .mono(fontSize * 0.88),
            codeBackground: palette.gray100,
            mathSplitter: mathSplitter
        ) {
            return Text(attributed)
        }
        return Text(markdown)
    }
}

extension View {
    /// Display math can overflow; allow horizontal scrolling where supported.
    @ViewBuilder
    func horizontalScrollIfAvailable() -> some View {
        ScrollView(.horizontal, showsIndicators: false) { self }
    }
}

// MARK: - Native markdown table

struct NativeMarkdownTable: View {
    @Environment(\.palette) private var palette
    let rows: [[String]]
    let fontSize: CGFloat

    var body: some View {
        let columnCount = rows.map(\.count).max() ?? 0
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(spacing: 0) {
                    ForEach(0..<max(columnCount, 1), id: \.self) { columnIndex in
                        Text(rowIndex < row.count ? cell(row[columnIndex]) : "")
                            .font(.system(size: fontSize * 0.92))
                            .foregroundStyle(rowIndex == 0 ? palette.gray800 : palette.gray700)
                            .fontWeight(rowIndex == 0 ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(palette.gray200).frame(width: 1) }
            }
        }
        .overlay(Rectangle().stroke(palette.gray200))
    }

    private func cell(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}

// MARK: - HTML table → native grid (replaces block.table_html dangerouslySetInnerHTML)

enum HTMLTableParser {
    /// 表格 HTML → 二维数组的解析结果缓存。
    /// 原来每次 body 求值都会跑一遍 NSRegularExpression;表格通常很大且内容不变,
    /// 滚动时反复求值等于反复全文匹配。
    private static let cache: NSCache<NSString, CachedTableRows> = {
        let cache = NSCache<NSString, CachedTableRows>()
        cache.countLimit = 200
        return cache
    }()

    /// 带缓存入口;`PaperTableView` 走这里。
    static func rows(for html: String) -> [[String]]? {
        let key = html as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = parse(html)
        cache.setObject(CachedTableRows(value), forKey: key)
        return value
    }

    static func parse(_ html: String) -> [[String]]? {
        guard html.contains("<table") else { return nil }
        var rows: [[String]] = []
        for rowMatch in matches(of: "<tr[^>]*>(.*?)</tr>", in: html) {
            let rowHtml = String(rowMatch.1)
            var cells: [String] = []
            for cellMatch in matches(of: "<t[dh][^>]*>(.*?)</t[dh]>", in: rowHtml) {
                cells.append(stripTags(String(cellMatch.1)))
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows.isEmpty ? nil : rows
    }

    private static func stripTags(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if let decoded = decodeNumericEntities(text) { text = decoded }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String? {
        guard text.contains("&#") else { return nil }
        var result = ""
        var scanner = Substring(text)
        while let amp = scanner.firstIndex(of: "&") {
            result += String(scanner[..<amp])
            let rest = scanner[amp...]
            if let semicolon = rest.firstIndex(of: "#") {
                let after = rest.index(after: semicolon)
                if let end = rest[after...].firstIndex(of: ";") {
                    let numberPart = String(rest[after..<end])
                    var scalarValue: UInt32?
                    if numberPart.hasPrefix("x") || numberPart.hasPrefix("X") {
                        scalarValue = UInt32(numberPart.dropFirst(), radix: 16)
                    } else {
                        scalarValue = UInt32(numberPart)
                    }
                    if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                        result += String(Character(scalar))
                        scanner = rest[rest.index(after: end)...]
                        continue
                    }
                }
            }
            result += "&"
            scanner = scanner[scanner.index(after: amp)...]
        }
        result += String(scanner)
        return result
    }

    private static func matches(of pattern: String, in text: String) -> [(Substring, Substring)] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let outer = Range(match.range(at: 0), in: text),
                  let inner = Range(match.range(at: 1), in: text) else { return nil }
            return (text[outer], text[inner])
        }
    }
}

// MARK: - Table block view

final class CachedTableRows {
    let value: [[String]]?
    init(_ value: [[String]]?) { self.value = value }
}

struct PaperTableView: View {
    @Environment(\.palette) private var palette
    let html: String
    var fontSize: CGFloat = 14

    var body: some View {
        Group {
            if let rows = HTMLTableParser.rows(for: html) {
                NativeMarkdownTable(rows: rows, fontSize: fontSize * 0.85)
            } else {
                Text("表格数据无法本地渲染").font(.system(size: fontSize * 0.8)).foregroundStyle(palette.gray500)
            }
        }
    }
}
