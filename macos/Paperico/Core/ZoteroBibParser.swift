import Foundation

/// A deliberately bounded BibTeX subset. Malformed records remain visible to the importer.
enum ZoteroBibParser {
    struct Entry: Equatable, Sendable {
        var key: String
        var type: String
        var metadata: PaperMetadata.Metadata
        var files: [String]
        var error: String?
    }

    static func parse(_ text: String) -> [Entry] {
        var scanner = Scanner(text)
        var entries: [Entry] = []
        while scanner.seekEntry() {
            let start = scanner.position
            var key = ""
            do {
                let type = scanner.word().lowercased()
                try scanner.expect("{")
                if type == "comment" || type == "preamble" { try scanner.skipBalanced(); continue }
                if type == "string" {
                    let name = scanner.word().lowercased()
                    try scanner.expect("=")
                    scanner.macros[name] = try scanner.value()
                    scanner.skip()
                    if scanner.peek == "," { scanner.position += 1 }
                    try scanner.expect("}")
                    continue
                }
                key = scanner.until([",", "}"]).trimmingCharacters(in: .whitespacesAndNewlines)
                try scanner.expect(",")
                var fields: [String: String] = [:]
                while true {
                    scanner.skip()
                    if scanner.peek == "}" { scanner.position += 1; break }
                    let name = scanner.word().lowercased()
                    guard !name.isEmpty else { throw ParseFailure("缺少字段名称") }
                    try scanner.expect("=")
                    fields[name] = try scanner.value()
                    scanner.skip()
                    if scanner.peek == "," { scanner.position += 1 }
                    else if scanner.peek != "}" { throw ParseFailure("字段之间缺少逗号") }
                }
                let year = clean(fields["year"] ?? "").range(of: #"\d{4}"#, options: .regularExpression)
                    .flatMap { Int(clean(fields["year"] ?? "")[$0]) }
                let rawAuthors = splitAuthors(fields["author"] ?? "")
                let authors = rawAuthors.map { raw -> String in
                    let parts = clean(raw).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    return parts.count == 2 ? parts.reversed().joined(separator: " ") : clean(raw)
                }.filter { !$0.isEmpty }
                let known = Set(["article", "inproceedings", "book", "misc", "phdthesis", "mastersthesis", "techreport", "online", "report"])
                entries.append(Entry(key: key, type: known.contains(type) ? type : "misc", metadata: .init(
                    title: clean(fields["title"] ?? ""), authors: authors, year: year,
                    venue: clean(fields["journal"] ?? fields["booktitle"] ?? fields["publisher"] ?? ""),
                    doi: PaperLibrary.normalizeDOI(clean(fields["doi"] ?? "")),
                    arxivId: PaperLibrary.normalizeArxivId(clean(fields["eprint"] ?? ""))
                ), files: attachmentPaths(fields["file"] ?? ""), error: nil))
            } catch {
                entries.append(Entry(key: key, type: "misc", metadata: .init(), files: [], error: error.localizedDescription))
                scanner.position = start
                scanner.recover()
            }
        }
        return entries
    }

    static func attachmentPaths(_ raw: String) -> [String] {
        raw.components(separatedBy: ";").compactMap { item in
            var path = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            if path.hasPrefix("file://"), let url = URL(string: path) { return url.path }
            // Zotero: description:path:application/pdf; JabRef: :path:PDF.
            if let suffix = path.range(of: #":(?:PDF|application/pdf)$"#, options: [.regularExpression, .caseInsensitive]) {
                path = String(path[..<suffix.lowerBound])
                if let colon = path.firstIndex(of: ":") { path = String(path[path.index(after: colon)...]) }
            }
            return path.replacingOccurrences(of: #"\:"#, with: ":").removingPercentEncoding ?? path
        }
    }

    static func clean(_ raw: String) -> String {
        var text = raw
        // Handle a finite accent vocabulary, leaving unsupported macros recognizable.
        for (command, mark) in [("'", "\u{0301}"), ("`", "\u{0300}"), ("\"", "\u{0308}"), ("^", "\u{0302}"), ("~", "\u{0303}")] {
            let pattern = NSRegularExpression.escapedPattern(for: "\\" + command) + #"\{?([A-Za-z])\}?"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                    let source = text as NSString
                    text = source.replacingCharacters(in: m.range, with: source.substring(with: m.range(at: 1)) + mark)
                }
            }
        }
        for character in ["&", "%", "_", "#", "$", "{", "}"] {
            text = text.replacingOccurrences(of: "\\" + character, with: character)
        }
        text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: "~", with: " ")
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").precomposedStringWithCanonicalMapping
    }

    private static func splitAuthors(_ value: String) -> [String] {
        let chars = Array(value)
        var depth = 0, start = 0, i = 0
        var result: [String] = []
        while i < chars.count {
            if chars[i] == "{" { depth += 1 }
            if chars[i] == "}" { depth = max(0, depth - 1) }
            if depth == 0, i + 5 <= chars.count, String(chars[i..<i+5]).lowercased() == " and " {
                result.append(String(chars[start..<i])); i += 5; start = i; continue
            }
            i += 1
        }
        result.append(String(chars[start...]))
        return result
    }

    private struct ParseFailure: LocalizedError {
        var errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    private struct Scanner {
        var chars: [Character]
        var position = 0
        var macros: [String: String] = [:]
        init(_ text: String) { chars = Array(text) }
        var peek: Character? { position < chars.count ? chars[position] : nil }
        mutating func skip() {
            while let c = peek {
                if c.isWhitespace { position += 1 }
                else if c == "%" { while let c = peek, c != "\n" { position += 1 } }
                else { break }
            }
        }
        mutating func seekEntry() -> Bool {
            while let c = peek {
                if c == "%" { skip(); continue }
                position += 1
                if c == "@" { return true }
            }
            return false
        }
        mutating func word() -> String {
            skip()
            let start = position
            while let c = peek, c.isLetter || c.isNumber || c == "_" || c == "-" { position += 1 }
            return String(chars[start..<position])
        }
        mutating func until(_ delimiters: Set<Character>) -> String {
            let start = position
            while let c = peek, !delimiters.contains(c) { position += 1 }
            return String(chars[start..<position])
        }
        mutating func expect(_ c: Character) throws {
            skip()
            guard peek == c else { throw ParseFailure("缺少 \(c)") }
            position += 1
        }
        mutating func skipBalanced() throws { _ = try enclosed(close: "}", nested: true) }
        mutating func enclosed(close: Character, nested: Bool) throws -> String {
            var depth = 1, value = ""
            while let c = peek {
                position += 1
                if c == "\\", let next = peek { value.append(c); value.append(next); position += 1; continue }
                if nested && c == "{" { depth += 1 }
                if c == close {
                    depth -= 1
                    if depth == 0 { return value }
                }
                value.append(c)
            }
            throw ParseFailure("字段括号或引号未闭合")
        }
        mutating func value() throws -> String {
            var value = ""
            repeat {
                skip()
                guard let c = peek else { throw ParseFailure("缺少字段值") }
                if c == "{" || c == "\"" {
                    position += 1
                    value += try enclosed(close: c == "{" ? "}" : "\"", nested: c == "{")
                } else {
                    let bare = until([",", "}", "#"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !bare.isEmpty else { throw ParseFailure("缺少字段值") }
                    value += macros[bare.lowercased()] ?? bare
                }
                skip()
                if peek != "#" { return value }
                position += 1
            } while true
        }
        mutating func recover() {
            // Restart at a line-leading entry so an unterminated value cannot swallow the rest.
            while position < chars.count {
                if chars[position] == "@", position == 0 || chars[position-1].isWhitespace { return }
                position += 1
            }
        }
    }
}
