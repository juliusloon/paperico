import Foundation

/// SDK-independent, read-only queries. Each read stays on the existing library
/// actor without suspension, including the active-paper check and file access.
struct LibraryAutomationOutput: Sendable {
    let json: Data
    var image: Data? = nil
    var mimeType: String? = nil
}

private struct AutomationArguments: Decodable {
    var paperId: String?
    var blockId: String?
    var projectId: String?
    var status: String?
    var query: String?
    var category: String?
    var offset: Int?
    var limit: Int?

    func identifier(_ value: String?) throws -> String {
        guard let value, !value.isEmpty, value.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw AutomationError("需要有效的 paper_id / block_id。")
        }
        return value
    }

    func page<T: Encodable>(_ items: [T]) throws -> AutomationPage<T> {
        let offset = offset ?? 0, limit = limit ?? 50
        guard offset >= 0, (1...200).contains(limit) else {
            throw AutomationError("offset 必须大于等于 0，limit 必须在 1–200 之间。")
        }
        let start = min(offset, items.count), end = start + min(limit, items.count - start)
        return AutomationPage(items: Array(items[start..<end]), total: items.count,
                              nextOffset: end < items.count ? end : nil)
    }
}

private struct AutomationPage<T: Encodable>: Encodable {
    let items: [T]
    let total: Int
    let nextOffset: Int?
}

private struct AutomationPaper: Encodable {
    let paper: PaperListItem
    let entities: [MethodEntity]
    let outline: [PaperOutlineEntry]
    let blockCount: Int
}

struct AutomationError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension PaperLibrary {
    func automationQuery(_ name: String, arguments: Data) throws -> LibraryAutomationOutput {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let args = try decoder.decode(AutomationArguments.self, from: arguments)
        switch name {
        case "list_papers", "search_library":
            if name == "search_library", args.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw AutomationError("search_library 需要非空 query。")
            }
            return try automationEncode(args.page(listPapers(projectId: args.projectId, status: args.status, q: args.query)))
        case "list_projects":
            return try automationEncode(args.page(listProjects()))
        case "get_method_index", "search_methods":
            if name == "search_methods", args.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw AutomationError("search_methods 需要非空 query。")
            }
            return try automationEncode(args.page(methodIndex(projectId: args.projectId, category: args.category, q: args.query)))
        case "get_paper", "get_blocks", "get_block", "get_figure", "get_notes",
             "resource_blocks", "resource_chat", "resource_notes":
            let paperId = try args.identifier(args.paperId)
            // Never expose retained files for trashed/permanently deleted papers.
            guard paper(id: paperId) != nil else { throw AutomationError("论文不存在或已移入回收站。") }
            switch name {
            case "get_paper":
                // The default paperDetail API writes last_opened_at; automation must not.
                let detail = try paperDetail(id: paperId, markOpened: false)
                return try automationEncode(AutomationPaper(paper: detail.paper, entities: detail.entities,
                    outline: PaperOutline.entries(detail.blocks), blockCount: detail.blocks.count))
            case "get_blocks":
                return try automationEncode(args.page(paperDetail(id: paperId, markOpened: false).blocks))
            case "get_block", "get_figure":
                let blockId = try args.identifier(args.blockId)
                guard let block = try paperDetail(id: paperId, markOpened: false).blocks.first(where: { $0.id == blockId }) else {
                    throw AutomationError("论文中没有这个 block_id。")
                }
                var result = try automationEncode(block)
                if name == "get_figure" {
                    guard let url = layout.fileURL(forRelativePath: block.imagePath) else {
                        throw AutomationError("这个块没有可读取的本地图像。")
                    }
                    // Constrain a figure to this paper's output, not merely the library root.
                    let base = layout.mineruOutputDir(paperId).standardizedFileURL.resolvingSymlinksInPath()
                    guard url.path.hasPrefix(base.path + "/") else { throw AutomationError("图像路径不属于这篇论文。") }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard size.isRegularFile == true, let bytes = size.fileSize, bytes <= 4 * 1024 * 1024 else {
                        throw AutomationError("图像必须为不超过 4 MiB 的普通文件。")
                    }
                    let image = try Data(contentsOf: url)
                    let mime: String
                    if image.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { mime = "image/png" }
                    else if image.starts(with: [255, 216, 255]) { mime = "image/jpeg" }
                    else if image.starts(with: Data("GIF8".utf8)) { mime = "image/gif" }
                    else if image.count >= 12, image.prefix(4) == Data("RIFF".utf8), image[8..<12] == Data("WEBP".utf8) { mime = "image/webp" }
                    else { throw AutomationError("仅支持 PNG、JPEG、GIF 或 WebP 图像。") }
                    result.image = image
                    result.mimeType = mime
                }
                return result
            case "get_notes": return try automationEncode(args.page(notes(paperId: paperId)))
            case "resource_blocks": return try automationEncode(paperDetail(id: paperId, markOpened: false).blocks)
            case "resource_chat": return try automationEncode(chatSessions(paperId: paperId))
            default: return try automationEncode(notes(paperId: paperId))
            }
        default:
            throw AutomationError("不支持的只读查询。")
        }
    }

    private func automationEncode<T: Encodable>(_ value: T) throws -> LibraryAutomationOutput {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 6 * 1024 * 1024 else { throw AutomationError("结果过大，请改用分页工具读取。") }
        return LibraryAutomationOutput(json: data)
    }
}
