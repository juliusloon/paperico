import SwiftUI

// MARK: - Native Markdown renderer (replaces react-markdown + remark-math + rehype-katex)
//
// SwiftUI has no KaTeX; LaTeX segments ($$…$$ display, $…$ inline) render as
// monospaced math blocks. Everything else (headings, lists, code, blockquotes,
// tables, links, emphasis) renders natively.

struct MarkdownText: View {
    @Environment(\.palette) private var palette

    let text: String
    var fontSize: CGFloat = 14
    var color: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: block parsing

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

    private func parseBlocks(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("$$") {
                flushParagraph()
                var math = trimmed.hasPrefix("$$") ? String(trimmed.dropFirst(2)) : ""
                if math.hasSuffix("$$"), math.count >= 2 {
                    math = String(math.dropLast(2))
                    blocks.append(.mathDisplay(math.trimmingCharacters(in: .whitespaces)))
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
                blocks.append(.mathDisplay(math.trimmingCharacters(in: .whitespaces)))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingLevel(of: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading, text: String(trimmed.dropFirst(heading)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
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
                while index < lines.count, isTableLine(lines[index].trimmingCharacters(in: .whitespaces)) {
                    rows.append(tableCells(lines[index].trimmingCharacters(in: .whitespaces)))
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
                while index < lines.count, isBullet(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    items.append(String(item.dropFirst(1)).trimmed)
                    index += 1
                }
                blocks.append(.unordered(items))
                continue
            }

            if let numberLength = orderedPrefixLength(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let n = orderedPrefixLength(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    items.append(String(item.dropFirst(n)).trimmed)
                    index += 1
                }
                blocks.append(.ordered(items))
                _ = numberLength
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private func headingLevel(of line: String) -> Int? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6, line.count > count else { return nil }
        let after = line[line.index(line.startIndex, offsetBy: count)]
        return after == " " ? count : nil
    }

    private func isBullet(_ line: String) -> Bool {
        (line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ "))
    }

    private func orderedPrefixLength(_ line: String) -> Int? {
        guard let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }) else { return nil }
        let digits = line[..<dot]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), dot < line.endIndex else { return nil }
        let after = line.index(after: dot)
        return after < line.endIndex && line[after] == " " ? line.distance(from: line.startIndex, to: after) + 1 : nil
    }

    private func isTableLine(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && line.contains("|")
    }

    private func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return isTableLine(trimmed) && trimmed.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private func tableCells(_ line: String) -> [String] {
        var content = line
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: block views

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        let baseColor = color ?? palette.gray800
        switch block {
        case .heading(let level, let text):
            inlineText(text)
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
        let prepared = InlineMathSplitter.inlineMathToCode(text)
        return inlineText(prepared)
            .font(.system(size: fontSize))
            .foregroundStyle(color)
    }

    private func inlineText(_ markdown: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if var attributed = try? AttributedString(markdown: markdown, options: options) {
            for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .mono(fontSize * 0.88)
                attributed[run.range].backgroundColor = palette.gray100
            }
            return Text(attributed)
        }
        return Text(markdown)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

extension View {
    /// Display math can overflow; allow horizontal scrolling where supported.
    @ViewBuilder
    func horizontalScrollIfAvailable() -> some View {
        ScrollView(.horizontal, showsIndicators: false) { self }
    }
}

// MARK: - Inline math handling

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

struct PaperTableView: View {
    @Environment(\.palette) private var palette
    let html: String
    var fontSize: CGFloat = 14

    var body: some View {
        Group {
            if let rows = HTMLTableParser.parse(html) {
                NativeMarkdownTable(rows: rows, fontSize: fontSize * 0.85)
            } else {
                Text("表格数据无法本地渲染").font(.system(size: fontSize * 0.8)).foregroundStyle(palette.gray500)
            }
        }
    }
}
