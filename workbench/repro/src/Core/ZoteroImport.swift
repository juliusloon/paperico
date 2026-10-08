import Foundation

enum ZoteroImport {
    struct Pair: Sendable { let entry: ZoteroBibParser.Entry; let pdf: URL }
    struct Plan: Sendable {
        var pairs: [Pair]
        var withoutMetadata: [URL]
        var unmatched: [ZoteroBibParser.Entry]
    }
    struct Report: Sendable {
        var imported: [PaperListItem] = []
        var withoutMetadata: [String] = []
        var duplicates: [String] = []
        var unmatched: [String] = []
        var failures: [String] = []
    }

    /// Every attachment is selected from the scanned folder, including absolute file URLs.
    static func pair(entries: [ZoteroBibParser.Entry], pdfs: [URL], folder: URL) -> Plan {
        let files = pdfs.sorted { $0.path < $1.path }
        var available = Set(files)
        var pairs: [Pair] = []
        var pairedEntries = Set<Int>()
        let canonical = Dictionary(uniqueKeysWithValues: files.map { ($0.standardizedFileURL.resolvingSymlinksInPath().path, $0) })
        // Exact references take priority globally over every fuzzy candidate.
        for (i, entry) in entries.enumerated() where entry.error == nil {
            for path in entry.files {
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
                if let file = canonical[url.standardizedFileURL.resolvingSymlinksInPath().path], available.remove(file) != nil {
                    pairs.append(Pair(entry: entry, pdf: file)); pairedEntries.insert(i); break
                }
            }
        }
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        for (i, entry) in entries.enumerated() where entry.error == nil && !pairedEntries.contains(i) {
            let names = ([entry.metadata.title, entry.key] + entry.files.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
                .map(normalized).filter { !$0.isEmpty }
            let candidates = files.filter { file in
                guard available.contains(file) else { return false }
                let stem = normalized(file.deletingPathExtension().lastPathComponent)
                return !stem.isEmpty && names.contains { stem.contains($0) || $0.contains(stem) }
            }
            // Ambiguous filenames remain explicit rather than silently attaching the wrong PDF.
            if candidates.count == 1, let file = candidates.first {
                available.remove(file); pairedEntries.insert(i); pairs.append(Pair(entry: entry, pdf: file))
            }
        }
        return Plan(pairs: pairs, withoutMetadata: files.filter { available.contains($0) },
                    unmatched: entries.enumerated().filter { !pairedEntries.contains($0.offset) }.map(\.element))
    }

    static func scan(folder: URL) throws -> Plan {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw AutomationError("无法读取导出文件夹。")
        }
        var bibs: [URL] = [], pdfs: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isSymbolicLink != true, properties.isRegularFile == true,
                  url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { continue }
            if url.pathExtension.lowercased() == "bib" { bibs.append(url) }
            if url.pathExtension.lowercased() == "pdf" { pdfs.append(url) }
        }
        guard bibs.count == 1, let bib = bibs.first else { throw AutomationError("导出文件夹必须恰好包含一个 .bib 文件，当前找到 \(bibs.count) 个。") }
        return pair(entries: ZoteroBibParser.parse(try String(contentsOf: bib, encoding: .utf8)), pdfs: pdfs, folder: bib.deletingLastPathComponent())
    }

    static func run(folder: URL, projectId: String?, library: PaperLibrary) async throws -> Report {
        let plan = try await Task.detached { try scan(folder: folder) }.value
        try Task.checkCancellation()
        var report = Report()
        report.unmatched = plan.unmatched.map { $0.key + ($0.error.map { "：" + $0 } ?? "：未找到唯一 PDF 附件") }
        let imports: [(URL, PaperMetadata.Metadata?)] = plan.pairs.map { ($0.pdf, $0.entry.metadata) } + plan.withoutMetadata.map { ($0, nil) }
        for (url, metadata) in imports {
            try Task.checkCancellation()
            do {
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                try Task.checkCancellation()
                let paper = try await library.importPDF(fileData: data, fileName: url.lastPathComponent, projectId: projectId, metadata: metadata)
                report.imported.append(paper)
                if metadata == nil { report.withoutMetadata.append(url.lastPathComponent) }
            } catch is CancellationError { throw CancellationError() }
            catch let error as PipelineError where error.errorCode == .duplicatePaper {
                report.duplicates.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            } catch { report.failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return report
    }
}
