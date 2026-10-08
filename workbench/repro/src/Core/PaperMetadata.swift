import Foundation

/// 从解析结果中识别 DOI / arXiv ID，并回填作者、年份与期刊。
///
/// 设计取舍（与 `PaperContentScope` 一致）：**识别失败保持现状，绝不阻塞管线。**
/// 元数据是锦上添花，解析与翻译才是主路径；一次 Crossref 抖动不该让一篇
/// 本来能读懂的论文变成 error。因此 `lookup` 任何一步失败都返回 nil。
enum PaperMetadata {

    struct Identifiers: Equatable, Sendable {
        var doi: String? = nil
        var arxivId: String? = nil
    }

    struct Metadata: Equatable, Sendable {
        var title: String = ""
        var authors: [String] = []
        var year: Int? = nil
        var venue: String = ""
        var doi: String? = nil
        var arxivId: String? = nil

        init(title: String = "", authors: [String] = [], year: Int? = nil,
             venue: String = "", doi: String? = nil, arxivId: String? = nil) {
            self.title = title
            self.authors = authors
            self.year = year
            self.venue = venue
            self.doi = doi
            self.arxivId = arxivId
        }
    }

    /// 外部查询各自的硬超时。对齐 `MinerUClient` 的"总时长预算"纪律：
    /// 新增外部调用不得引入无限等待。
    static let requestTimeout: TimeInterval = 8
    /// 回退扫描的前若干个块——DOI 通常在首页的出版信息里。
    static let leadingBlockScanLimit = 12
    /// 作者数量上限，避免超长作者列表把 UI 撑破。
    static let authorLimit = 20

    // MARK: - 识别

    /// 优先从「出版信息」区取（DOI 就在那里），回退到前若干块的原文。
    static func extractIdentifiers(from blocks: [Block]) -> Identifiers {
        guard !blocks.isEmpty else { return Identifiers() }
        let regions = PaperContentScope.regions(blocks)
        // frontMatter = 标题/作者/单位/版权等出版信息；DOI 通常就在这一段里。
        let publication = blocks.indices
            .filter { regions[$0] == .frontMatter }
            .map { blocks[$0].textOriginal }
        let leading = blocks.prefix(leadingBlockScanLimit).map(\.textOriginal)
        // 去重但保序：同一段文本可能同时命中两个来源。
        var seen = Set<String>()
        let candidates = (publication + leading).filter { seen.insert($0).inserted }

        return extractIdentifiers(publicationTexts: candidates)
    }

    /// Also used by the parser to retain first-page identifier-bearing headers
    /// and footers that would otherwise disappear before recognition.
    static func extractIdentifiers(publicationTexts: [String]) -> Identifiers {
        Identifiers(
            doi: firstMatch(of: Self.doiPattern, in: publicationTexts),
            arxivId: firstMatch(of: Self.arxivPattern, in: publicationTexts)?.replacingOccurrences(
                of: #"^arXiv[:\s]\s*"#, with: "", options: [.regularExpression, .caseInsensitive]
            )
        )
    }

    private static let doiPattern = #"10\.\d{4,9}/[^\s"'<>,;]+"#
    private static let arxivPattern = #"arXiv[:\s]\s*(\d{4}\.\d{4,5}(?:v\d+)?)"#

    private static func firstMatch(of pattern: String, in texts: [String]) -> String? {
        for text in texts {
            guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            var value = String(text[range])
            // "https://doi.org/10.xxxx/yyy" → "10.xxxx/yyy"，便于去重与展示。
            if let doiRange = value.range(of: #"10\.\d{4,9}/"#, options: .regularExpression) {
                value = String(value[doiRange.lowerBound...])
            }
            while let last = value.last, ".,;:".contains(last) { value.removeLast() }
            // Parentheses are legal inside a DOI (e.g. older Elsevier papers).
            // Remove only unmatched punctuation belonging to the surrounding text.
            for (opening, closing) in [("(", ")"), ("[", "]")] {
                while value.hasSuffix(closing),
                      value.filter({ String($0) == closing }).count > value.filter({ String($0) == opening }).count {
                    value.removeLast()
                }
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - 查询

    /// 命中 DOI 走 Crossref，命中 arXiv 走 Atom。**各 8 秒硬超时，失败静默返回 nil。**
    static func lookup(
        doi: String? = nil, arxivId: String? = nil,
        session: URLSession = .shared
    ) async -> Metadata? {
        guard let doi, !doi.isEmpty else {
            guard let arxivId, !arxivId.isEmpty else { return nil }
            return await lookupArxiv(arxivId, session: session)
        }
        return await lookupCrossref(doi, session: session)
    }

    private static func lookupCrossref(_ doi: String, session: URLSession) async -> Metadata? {
        // DOI 里可能带尾随标点（见 extractIdentifiers），查询前归一化。
        let normalized = doi.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        let pathCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: pathCharacters),
              let url = URL(string: "https://api.crossref.org/works/\(encoded)") else { return nil }
        guard let data = await fetch(url, session: session),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? [String: Any] else { return nil }

        var metadata = Metadata(doi: normalized)
        metadata.title = firstString(message["title"])
        metadata.authors = Array(
            (message["author"] as? [[String: Any]] ?? []).compactMap { author -> String? in
                let given = firstString(author["given"]), family = firstString(author["family"])
                let name = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                return name.isEmpty ? nil : name
            }.prefix(authorLimit)
        )
        metadata.year = (message["issued"] as? [String: Any])
            .flatMap { $0["date-parts"] as? [[Int]] }?.first?.first
        metadata.venue = firstString(message["container-title"])
        return metadata
    }

    private static func lookupArxiv(_ arxivId: String, session: URLSession) async -> Metadata? {
        let id = arxivId.lowercased().replacingOccurrences(of: "arxiv:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(encoded)") else { return nil }
        guard let data = await fetch(url, session: session),
              let text = String(data: data, encoding: .utf8),
              let entry = text.range(of: #"(?s)<entry>(.*?)</entry>"#, options: .regularExpression)
                .map({ String(text[$0]) }) else { return nil }

        var metadata = Metadata(arxivId: id)
        metadata.title = firstXMLTag("title", in: entry) ?? ""
        metadata.authors = Array(xmlValues("name", in: entry).prefix(authorLimit))
        metadata.year = firstXMLTag("published", in: entry)
            .flatMap { Int($0.prefix(4)) }
        // arXiv 没有真正的期刊名，用 primary category 表达更有信息量。
        // 该元素是自闭合标签（<arxiv:primary_category term="cs.LG"/>），
        // 因此不能靠成对标签的正则去取内容。
        metadata.venue = firstAttribute("term", ofTag: "arxiv:primary_category", in: entry)
            .map { "arXiv \($0)" } ?? "arXiv"
        return metadata
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue("Paperico/1.1 (metadata lookup)",
                         forHTTPHeaderField: "User-Agent")
        // URLRequest's timeout is an inactivity limit. Race the entire exchange
        // against a deadline so a slowly streaming response cannot hold the pipeline.
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else { return nil }
                    return data
                } catch { return nil }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(requestTimeout))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private static func firstString(_ value: Any?) -> String {
        if let list = value as? [String] { return list.first ?? "" }
        return (value as? String) ?? ""
    }

    /// Value of `attribute` on the first `tag` element, for self-closing tags.
    private static func firstAttribute(_ attribute: String, ofTag tag: String, in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)([^>]*)/?>") else { return nil }
        let ns = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let attributes = match.range(at: 1)
        guard attributes.location != NSNotFound else { return nil }
        return capture("\(attribute)=\"([^\"]+)\"", in: ns.substring(with: attributes))
    }

    /// First capture group of `pattern` in `source`, if the pattern matches.
    private static func capture(_ pattern: String, in source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let group = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[group])
    }

    private static func firstXMLTag(_ tag: String, in xml: String) -> String? {
        xmlValues(tag, in: xml).first
    }

    private static func xmlValues(_ tag: String, in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)[^>]*>(.*?)</\(tag)>", options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Range(match.range(at: 1), in: xml).map { String(xml[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

extension PaperListItem {
    /// 把识别结果写入记录。**`metaSource == "manual"` 时完全不动**——
    /// 用户手改过的元数据是权威值，自动识别不得覆盖。
    @discardableResult
    mutating func apply(metadata: PaperMetadata.Metadata) -> Bool {
        guard metaSource != MetaSource.manual else { return false }
        var changed = false
        if !metadata.title.isEmpty, title.isEmpty { title = metadata.title; changed = true }
        if !metadata.authors.isEmpty, authors.isEmpty { authors = metadata.authors; changed = true }
        if let year = metadata.year, self.year == nil { self.year = year; changed = true }
        if !metadata.venue.isEmpty, venue.isEmpty { venue = metadata.venue; changed = true }
        if let doi = metadata.doi, self.doi == nil { self.doi = doi; changed = true }
        if let arxivId = metadata.arxivId, self.arxivId == nil { self.arxivId = arxivId; changed = true }
        if changed { metaSource = MetaSource.auto }
        return changed
    }
}
