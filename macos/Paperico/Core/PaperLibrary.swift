import Foundation
import CryptoKit

/// 数据目录布局(非隔离,视图层可同步取本地文件 URL)。
struct LibraryLayout: Sendable {
    let root: URL

    func pdfURL(_ id: String) -> URL { root.appendingPathComponent("pdfs/\(id).pdf") }
    func paperDir(_ id: String) -> URL { root.appendingPathComponent("papers/\(id)", isDirectory: true) }
    func mineruOutputDir(_ id: String) -> URL { root.appendingPathComponent("mineru_output/\(id)", isDirectory: true) }
    func analysesDir(_ id: String) -> URL { root.appendingPathComponent("analyses/\(id)", isDirectory: true) }
    func blocksFile(_ id: String) -> URL { paperDir(id).appendingPathComponent("blocks.json") }
    func entitiesFile(_ id: String) -> URL { paperDir(id).appendingPathComponent("entities.json") }
    func chatFile(_ id: String) -> URL { paperDir(id).appendingPathComponent("chat.json") }
    func notesFile(_ id: String) -> URL { paperDir(id).appendingPathComponent("notes.json") }

    /// 把相对引用还原成本地文件 URL(Block.imagePath 等)。
    func fileURL(forRelativePath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        guard !path.hasPrefix("/") else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// 本地论文库(替代原 FastAPI 后端的持久层)。
///
/// 数据全部落在 App 沙盒容器内:
///   Application Support/Paperico/
///     library.json                项目 + 论文索引(轻量)
///     pdfs/<id>.pdf               原始 PDF
///     papers/<id>/blocks.json     解析块
///     papers/<id>/entities.json   方法实体
///     papers/<id>/chat.json       对话会话
///     papers/<id>/notes.json      笔记
///     mineru_output/<id>/…        MinerU 解包结果(图片路径按相对引用记录)
///     analyses/<id>/…             LLM 原始响应 sidecar
///
/// Block/ChatMessage 等复用 Models.swift 里的既有 DTO,Codable 序列化,
/// 视图层零改动;image_path/pdf 一律本地文件 URL,不再有 /api/files。
actor PaperLibrary {

    private let root: URL
    let layout: LibraryLayout
    private var index = LibraryIndex()
    private var committedIndex = LibraryIndex()
    private var loaded = false
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL? = nil) {
        let base = root ?? AppPaths.appSupport
        self.root = base
        self.layout = LibraryLayout(root: base)
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = e
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = d
    }

    // MARK: - 目录布局

    var dataRoot: URL { root }
    var libraryFile: URL { root.appendingPathComponent("library.json") }
    func pdfURL(_ id: String) -> URL { layout.pdfURL(id) }
    func paperDir(_ id: String) -> URL { layout.paperDir(id) }
    func mineruOutputDir(_ id: String) -> URL { layout.mineruOutputDir(id) }
    func analysesDir(_ id: String) -> URL { layout.analysesDir(id) }
    func blocksFile(_ id: String) -> URL { layout.blocksFile(id) }
    func entitiesFile(_ id: String) -> URL { layout.entitiesFile(id) }
    func chatFile(_ id: String) -> URL { layout.chatFile(id) }
    func notesFile(_ id: String) -> URL { layout.notesFile(id) }

    // MARK: - 装载与落盘

    func load() throws {
        guard !loaded else { return }
        // 迁移前备份:成功迁移后保留(不自动删除),失败时原文件分毫未动。
        let onDiskVersion = try backupIndexBeforeMigration()
        index = try LibraryFiles.readJSON(libraryFile, decoder: decoder) ?? LibraryIndex()
        committedIndex = index
        // 启动对账(对齐 reconcile_interrupted_papers):上次退出时仍在处理中的论文标记为中断。
        let interrupted = ["parsing", "parsed", "normalizing", "analyzing", "reducing"]
        // 迁移本身也是一次改动：把新版本号落盘，下次启动不再重复迁移。
        // 必须比对**磁盘上**的版本——解码后内存里已经是 current 了。
        var changed = onDiskVersion < LibraryIndexMigrations.current
        for i in index.papers.indices where interrupted.contains(index.papers[i].status) {
            index.papers[i].status = "error"
            index.papers[i].errorMessage = "处理在应用退出时被中断，请重新解析或重新翻译。"
            index.papers[i].errorCode = ErrorCode.interruptedByRestart.rawValue
            changed = true
        }
        // Preserve legacy/unrecognized categories alongside all eight presets.
        if let items = try? methodIndex() {
            for item in items where !index.methodGroups.contains(where: { $0.id == item.category }) {
                index.methodGroups.append(MethodGroup(id: item.category, name: item.category))
                changed = true
            }
        }
        if changed { try persistIndex() }
        loaded = true
    }

    /// 复制一份迁移前的 `library.json`，并返回磁盘上的 schema 版本
    /// （无 `library.json` 时返回 current，表示无事可做）。只对 v1（含无版本）
    /// 索引做一次备份：已是当前版本的库不产生副本，避免每次启动堆积文件。
    private func backupIndexBeforeMigration() throws -> Int {
        guard let data = try? Data(contentsOf: libraryFile) else { return LibraryIndexMigrations.current }
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A nil key means the unversioned index, i.e. v1.
        let version = (object?["schema_version"] as? Int) ?? 1
        guard version < LibraryIndexMigrations.current else { return version }
        let stamp = Self.now().replacingOccurrences(of: ":", with: "-")
        let backup = libraryFile.deletingLastPathComponent()
            .appendingPathComponent("library.json.bak-v\(version)-\(stamp)")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return version }
        do { try data.write(to: backup, options: .atomic) }
        catch { throw PipelineError("无法备份论文库索引：\(error.localizedDescription)。原文件已保留。", .storageFailed) }
        return version
    }

    private func persistIndex() throws {
        do {
            try LibraryFiles.writeJSON(index, to: libraryFile, encoder: encoder)
            committedIndex = index
        } catch {
            index = committedIndex
            throw error
        }
    }

    private func requirePaper(_ id: String) throws {
        try Task.checkCancellation()
        guard paper(id: id) != nil else {
            throw PipelineError("论文已移入回收站或不存在", .internalError)
        }
    }

    private func paperRecord(_ id: String) -> Int? {
        index.papers.firstIndex { $0.id == id }
    }

    // MARK: - 项目

    func createProject(name: String, description: String) throws -> ProjectGroup {
        let name = try GroupName.validate(name, existing: index.projects.map(\.name))
        let project = ProjectGroup(
            id: Self.newId(), name: name, description: description,
            colorTag: "", paperCount: 0, createdAt: Self.now()
        )
        index.projects.append(project)
        try persistIndex()
        return project
    }

    func listProjects() -> [ProjectGroup] {
        index.projects.map { project in
            var updated = project
            updated.paperCount = index.papers.filter { $0.projectId == project.id }.count
            return updated
        }
    }

    func updateProject(id: String, name: String, description: String) throws -> ProjectGroup {
        guard let projectIndex = index.projects.firstIndex(where: { $0.id == id }) else {
            throw PipelineError("Project not found", .internalError)
        }
        var project = index.projects[projectIndex]
        project.name = try GroupName.validate(name, existing: index.projects.filter { $0.id != id }.map(\.name))
        project.description = description
        index.projects[projectIndex] = project
        try persistIndex()
        return listProjects().first { $0.id == id } ?? project
    }

    func deleteProject(id: String) throws {
        // 删除分组但保留论文(对齐后端 unlink 语义)。
        for i in index.papers.indices where index.papers[i].projectId == id {
            index.papers[i].projectId = nil
        }
        index.projects.removeAll { $0.id == id }
        try persistIndex()
    }

    // MARK: - 论文入库

    /// 导入 PDF:落盘 + sha256 去重(对齐 create_paper 的 T1.4 语义)。
    func importPDF(fileData: Data, fileName: String, projectId: String?) throws -> PaperListItem {
        guard fileName.lowercased().hasSuffix(".pdf") else {
            throw PipelineError("Only PDF files are supported", .pdfMissing)
        }
        guard fileData.starts(with: Data("%PDF-".utf8)) else {
            throw PipelineError("The uploaded file is not a valid PDF", .pdfMissing)
        }
        let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
        if let duplicateId = index.shaByPaperId.first(where: { key, sha in
            sha == digest && index.papers.contains { $0.id == key }
        })?.key,
           let duplicate = index.papers.first(where: { $0.id == duplicateId }) {
            let label = duplicate.displayTitle
            throw PipelineError("与已有论文《\(label)》重复（id \(duplicate.id)）", .duplicatePaper)
        }
        if index.trash.contains(where: { index.shaByPaperId[$0.id] == digest }) {
            throw PipelineError("该 PDF 已在回收站中，请恢复已有论文。", .duplicatePaper)
        }

        let id = Self.newId()
        try LibraryFiles.writeData(fileData, to: pdfURL(id))
        var paper = PaperListItem.empty(id: id)
        paper.projectId = projectId
        paper.sourceType = "pdf_upload"
        paper.originalFileName = fileName
        index.shaByPaperId[id] = digest

        index.papers.insert(paper, at: 0)
        try persistIndex()
        return paper
    }

    // MARK: - URL 导入(暂无 UI 入口,管线保留 pdf_url 提交路径)

    func importSourceURL(_ urlString: String, projectId: String?) throws -> PaperListItem {
        let id = Self.newId()
        var paper = PaperListItem.empty(id: id)
        paper.projectId = projectId
        paper.sourceType = urlString.hasSuffix(".pdf") || urlString.contains("/pdf/") ? "url_pdf" : "url_html"
        paper.originalFileName = String(urlString.split(separator: "/").last?.prefix(100) ?? "")
        index.sourceUrlByPaperId[id] = urlString
        index.papers.insert(paper, at: 0)
        try persistIndex()
        return paper
    }

    func sourceURL(paperId: String) -> String? {
        index.sourceUrlByPaperId[paperId]
    }

    /// 与已有论文相同的 DOI / arXiv ID —— 去重键的第二维度（第一维度是 SHA-256）。
    ///
    /// 调用时机：解析完成、标识符从原文提取并落盘之后，联网查询与模型分析之前
    /// （`PaperPipeline` 通过 `registerIdentifiers` 原子登记后调用本查询）。
    ///
    /// 同一篇论文的两个版本（预印本 + 正式发表）内容不同、SHA 不同，
    /// 但 DOI 相同，应当视为重复。
    func existingPaper(doi: String?, arxivId: String?, excluding id: String? = nil) -> PaperListItem? {
        let normalizedDOI = Self.normalizeDOI(doi)
        let normalizedArxiv = Self.normalizeArxivId(arxivId)
        guard normalizedDOI != nil || normalizedArxiv != nil else { return nil }
        return index.papers.first { record in
            guard record.id != id else { return false }
            if let owner = index.metadataDuplicateByPaperId[record.id],
               index.papers.contains(where: { $0.id == owner }) { return false }
            if let normalizedDOI, Self.normalizeDOI(record.doi) == normalizedDOI { return true }
            if let normalizedArxiv, Self.normalizeArxivId(record.arxivId) == normalizedArxiv { return true }
            return false
        }
    }

    /// Persist identifiers and reserve their owner in one actor turn. Separate
    /// write/query awaits let two concurrent parsers reject each other.
    func registerIdentifiers(_ ids: PaperMetadata.Identifiers, paperId: String) throws -> PaperListItem? {
        try requirePaper(paperId)
        guard let i = paperRecord(paperId), index.papers[i].metaSource != MetaSource.manual else { return nil }
        let duplicate = existingPaper(doi: ids.doi, arxivId: ids.arxivId, excluding: paperId)
        if index.papers[i].doi == nil { index.papers[i].doi = Self.normalizeDOI(ids.doi) }
        if index.papers[i].arxivId == nil { index.papers[i].arxivId = Self.normalizeArxivId(ids.arxivId) }
        // Ownership survives later parse errors/cancellation and restart reconciliation.
        index.metadataDuplicateByPaperId[paperId] = duplicate?.id
        try persistIndex()
        return duplicate
    }

    static func normalizeDOI(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:https?://(?:dx\.)?doi\.org/)"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;: "))
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `arXiv:2501.01234v2` → `2501.01234`（版本后缀不参与去重）。
    static func normalizeArxivId(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.lowercased()
            .replacingOccurrences(of: #"^arxiv[:\s]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 写入识别出的元数据。返回是否真的改了内容（`manual` 记录永远返回 false）。
    @discardableResult
    func applyMetadata(paperId: String, _ metadata: PaperMetadata.Metadata) throws -> Bool {
        guard let i = paperRecord(paperId) else { return false }
        let changed = index.papers[i].apply(metadata: metadata)
        if changed { try persistIndex() }
        return changed
    }

    /// 标记为用户手改：此后自动识别不再覆盖。
    func markMetadataManual(paperId: String, fields: Set<String>) throws {
        guard let i = paperRecord(paperId), !fields.isEmpty else { return }
        // 有实际值的字段才置manual，避免"什么都没改"也锁死自动填充。
        let record = index.papers[i]
        let touched = fields.contains { field in
            switch field {
            case "title": return !record.title.isEmpty
            case "authors": return !record.authors.isEmpty
            case "year": return record.year != nil
            case "venue": return !record.venue.isEmpty
            case "doi": return record.doi != nil
            case "arxivId": return record.arxivId != nil
            default: return false
            }
        }
        guard touched, index.papers[i].metaSource != MetaSource.manual else { return }
        index.papers[i].metaSource = MetaSource.manual
        try persistIndex()
    }

    // MARK: - 论文列表/详情

    func listPapers(projectId: String? = nil, status: String? = nil, q: String? = nil) -> [PaperListItem] {
        let query = q?.trimmingCharacters(in: .whitespacesAndNewlines)
        return index.papers.filter { paper in
            if let projectId, !projectId.isEmpty, paper.projectId != projectId { return false }
            if let status, !status.isEmpty, paper.status != status { return false }
            if let query, !query.isEmpty,
               !paper.title.localizedCaseInsensitiveContains(query),
               !paper.titleZh.localizedCaseInsensitiveContains(query),
               !paper.originalFileName.localizedCaseInsensitiveContains(query) { return false }
            return true
        }
    }

    func paper(id: String) -> PaperListItem? {
        index.papers.first { $0.id == id }
    }

    func paperDetail(id: String, markOpened: Bool = true) throws -> PaperDetail {
        guard let record = paper(id: id) else {
            throw PipelineError("没有找到这篇论文", .internalError)
        }
        var detail = PaperDetail(paper: record, blocks: [], entities: [])
        if let blocks: [Block] = try LibraryFiles.readJSON(blocksFile(id), decoder: decoder) {
            detail.blocks = blocks
        }
        let entities: [MethodEntity] = try LibraryFiles.readJSON(entitiesFile(id), decoder: decoder) ?? []
        detail.entities = entities
        // 块级实体引用在读取时构建(后端存关联表,这里由 blockRefs 反推)。
        detail.blocks = detail.blocks.map { block in
            var updated = block
            updated.entityRefs = entities.filter { $0.blockRefs.contains(block.id) }.map(\.id)
            return updated
        }
        // 打开即更新 last_opened_at(对齐 get_paper)。
        if markOpened, let i = paperRecord(id) {
            index.papers[i].lastOpenedAt = Self.now()
            try persistIndex()
            detail.paper = index.papers[i]
        }
        return detail
    }

    func writeBlocks(paperId: String, blocks: [Block]) throws {
        try requirePaper(paperId)
        try LibraryFiles.writeJSON(blocks, to: blocksFile(paperId), encoder: encoder)
    }

    func writeEntities(paperId: String, entities: [MethodEntity]) throws {
        try requirePaper(paperId)
        try LibraryFiles.writeJSON(entities, to: entitiesFile(paperId), encoder: encoder)
        let newKeys = Set(entities.map(\.canonicalKey)).filter { index.methodAddedAt[$0] == nil }
        let newCategories = Set(entities.filter { !index.hiddenMethods.contains(methodKey($0.canonicalKey)) }
            .map { index.methodContent[methodKey($0.canonicalKey)]?.category ?? $0.category })
            .subtracting(index.methodGroups.map(\.id)).sorted()
        if !newKeys.isEmpty || !newCategories.isEmpty {
            let timestamp = Self.now()
            for key in newKeys { index.methodAddedAt[key] = timestamp }
            for category in newCategories {
                let label = MethodGroup.presets.first { $0.id == category }?.name ?? category
                let name = index.methodGroups.contains { $0.name == label } ? "\(label)（\(category)）" : label
                index.methodGroups.append(MethodGroup(id: category, name: name))
            }
            try persistIndex()
        }
    }

    func readBlocks(paperId: String) throws -> [Block] {
        try LibraryFiles.readJSON(blocksFile(paperId), decoder: decoder) ?? []
    }

    func readEntities(paperId: String) throws -> [MethodEntity] {
        try LibraryFiles.readJSON(entitiesFile(paperId), decoder: decoder) ?? []
    }

    // MARK: - 状态与元数据

    func setStatus(paperId: String, status: String, errorMessage: String = "", errorCode: String? = nil) throws {
        guard let i = paperRecord(paperId) else { return }
        index.papers[i].status = status
        index.papers[i].errorMessage = errorMessage
        index.papers[i].errorCode = errorCode
        try persistIndex()
    }

    func renamePaper(id: String, title: String) throws -> PaperListItem {
        guard let i = paperRecord(id) else {
            throw PipelineError("Paper not found", .internalError)
        }
        index.papers[i].title = title
        // 用户改过标题即视为手改元数据，自动识别不再覆盖。
        index.papers[i].metaSource = MetaSource.manual
        try persistIndex()
        return index.papers[i]
    }

    /// One actor turn updates all user fields and the manual authority marker.
    @discardableResult
    func editMetadata(id: String, metadata: PaperMetadata.Metadata) throws -> PaperListItem {
        try requirePaper(id)
        guard let i = paperRecord(id) else { throw PipelineError("Paper not found", .internalError) }
        let doi = Self.normalizeDOI(metadata.doi)
        let arxiv = Self.normalizeArxivId(metadata.arxivId)
        if let duplicate = existingPaper(doi: doi, arxivId: arxiv, excluding: id) {
            throw PipelineError("与已有论文《\(duplicate.displayTitle)》的标识符重复", .duplicatePaper)
        }
        index.papers[i].title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        index.papers[i].authors = metadata.authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        index.papers[i].year = metadata.year
        index.papers[i].venue = metadata.venue.trimmingCharacters(in: .whitespacesAndNewlines)
        index.papers[i].doi = doi
        index.papers[i].arxivId = arxiv
        index.papers[i].metaSource = MetaSource.manual
        index.metadataDuplicateByPaperId[id] = nil
        try persistIndex()
        return index.papers[i]
    }

    func movePapers(paperIds: [String], projectId: String?) throws -> Int {
        var moved = 0
        for paperId in paperIds {
            guard let i = paperRecord(paperId) else { continue }
            index.papers[i].projectId = projectId
            moved += 1
        }
        try persistIndex()
        return moved
    }

    /// Soft-delete preserves all PDF, parsed content, chat and notes until restored or permanently deleted.
    func deletePaper(id: String) throws {
        guard let record = paper(id: id) else { return }
        index.trash.insert(TrashedPaper(paper: record, deletedAt: Self.now()), at: 0)
        index.papers.removeAll { $0.id == id }
        try persistIndex()
    }

    func listTrash() -> [TrashedPaper] { index.trash }

    // MARK: - 孤儿文件（只报告，不动作）

    /// 启动时扫描一次：`papers/`、`mineru_output/`、`analyses/` 与 `pdfs/` 下
    /// 存在、但索引（含回收站）里没有对应 ID 的条目。
    ///
    /// 只列两层、不递归统计体积——库很大时递归 stat 会拖慢启动，而用户需要的
    /// 只是"这里有东西、占多大"。
    func orphanFiles() -> [OrphanEntry] {
        let known = Set(index.papers.map(\.id)).union(index.trash.map(\.id))
        var found: [OrphanEntry] = []
        let directories: [(String, OrphanEntry.Kind)] = [
            ("papers", .paperDirectory), ("mineru_output", .mineruOutput), ("analyses", .analyses)
        ]
        for (folder, kind) in directories {
            let base = root.appendingPathComponent(folder, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for name in names.sorted() where !known.contains(name) {
                let url = base.appendingPathComponent(name, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                found.append(OrphanEntry(path: "\(folder)/\(name)", kind: kind,
                                         sizeBytes: Self.directorySize(url)))
            }
        }
        // pdfs/<id>.pdf 没有 id 之外的文件名，单独处理。
        let pdfBase = root.appendingPathComponent("pdfs", isDirectory: true)
        let pdfNames = (try? FileManager.default.contentsOfDirectory(atPath: pdfBase.path)) ?? []
        for name in pdfNames.sorted() where name.hasSuffix(".pdf") {
            let id = String(name.dropLast(4))
            guard !known.contains(id) else { continue }
            let url = pdfBase.appendingPathComponent(name)
            found.append(OrphanEntry(path: "pdfs/\(name)", kind: .pdf, sizeBytes: Self.directorySize(url)))
        }
        return found.sorted { $0.path < $1.path }
    }

    /// 删除一条孤儿记录。**调用方必须先拿到用户显式确认**——这里只负责执行，
    /// 且失败时保留记录以便重试（对齐永久删除的逐步逻辑）。
    func deleteOrphan(_ entry: OrphanEntry) throws {
        guard orphanFiles().contains(entry) else {
            throw PipelineError("这条未引用文件已经不存在了，请刷新后重试。", .storageFailed)
        }
        let url = root.appendingPathComponent(entry.path)
        do { try FileManager.default.removeItem(at: url) }
        catch { throw PipelineError("无法删除 \(entry.path)：\(error.localizedDescription)。请重试。", .storageFailed) }
    }

    /// 目录属性里的粗略体积，不递归遍历。
    private static func directorySize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return 0 }
        return Int64(values?.fileSize ?? 0)
    }

    /// Only an explicitly selected trash entry may be purged. Keep the entry on
    /// failure so cleanup can be retried, including when some files are missing.
    func permanentlyDeletePaper(id: String) throws {
        guard index.trash.contains(where: { $0.id == id }) else {
            throw PipelineError("只能永久删除回收站中的论文。", .storageFailed)
        }
        // Check index persistence before making any irreversible file changes.
        try persistIndex()
        for url in [pdfURL(id), paperDir(id), mineruOutputDir(id), analysesDir(id)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) }
            catch {
                throw PipelineError("无法永久删除论文文件：\(error.localizedDescription)。请重试删除。", .storageFailed)
            }
        }
        index.trash.removeAll { $0.id == id }
        index.shaByPaperId[id] = nil
        index.sourceUrlByPaperId[id] = nil
        index.metadataDuplicateByPaperId[id] = nil
        try persistIndex()
    }

    func restorePaper(id: String) throws {
        guard let entry = index.trash.first(where: { $0.id == id }) else { return }
        var record = entry.paper
        if let projectId = record.projectId, !index.projects.contains(where: { $0.id == projectId }) {
            record.projectId = nil
        }
        if record.statusEnum.isActive {
            record.status = "error"
            record.errorMessage = "处理已停止，可重新解析或重新翻译。"
            record.errorCode = ErrorCode.cancelled.rawValue
        }
        index.papers.insert(record, at: 0)
        index.trash.removeAll { $0.id == id }
        try persistIndex()
    }

    func updatePaper(_ mutate: (inout PaperListItem) -> Void) throws {
        var changed = false
        for i in index.papers.indices {
            var record = index.papers[i]
            mutate(&record)
            if record != index.papers[i] {
                index.papers[i] = record
                changed = true
            }
        }
        if changed { try persistIndex() }
    }

    // MARK: - 跨论文方法索引(对齐 library_api)

    func methodIndex(projectId: String? = nil, category: String? = nil, q: String? = nil) throws -> [MethodIndexItem] {
        // User index edits remain separate from the paper's extracted evidence.
        // Aliases combine sources before applying category/search filters.
        var grouped: [String: [(entity: MethodEntity, paperId: String)]] = [:]
        for record in index.papers {
            let paperEntities = try readEntities(paperId: record.id)
            for entity in paperEntities {
                let key = methodKey(entity.canonicalKey)
                if index.hiddenMethods.contains(key) { continue }
                grouped[key, default: []].append((entity, record.id))
            }
        }

        var items: [MethodIndexItem] = []
        for (key, entries) in grouped {
            var paperIds = Array(Set(entries.map(\.paperId))).sorted()
            if let projectId, !projectId.isEmpty {
                paperIds = paperIds.filter { pid in paper(id: pid)?.projectId == projectId }
                if paperIds.isEmpty { continue }
            }
            var papers: [MethodIndexPaper] = []
            for pid in paperIds {
                guard let record = paper(id: pid) else { continue }
                let blockIds = Set(entries.filter { $0.paperId == pid }.flatMap { $0.entity.blockRefs })
                papers.append(MethodIndexPaper(paperId: pid, title: record.displayTitle, blockIds: Array(blockIds).sorted()))
            }
            if papers.isEmpty { continue }
            let first = entries.first { $0.entity.canonicalKey == key }?.entity ?? entries[0].entity
            let content = index.methodContent[key] ?? MethodIndexContent(name: first.name, category: first.category, definitionZh: first.definitionZh)
            if let category, !category.isEmpty, content.category != category { continue }
            if let q, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !content.name.localizedCaseInsensitiveContains(q.trimmingCharacters(in: .whitespacesAndNewlines)) { continue }
            let addedAt = entries.compactMap { index.methodAddedAt[$0.entity.canonicalKey] ?? paper(id: $0.paperId)?.createdAt }.min()
            items.append(MethodIndexItem(
                canonicalKey: key, name: content.name, category: content.category,
                definitionZh: content.definitionZh, papers: papers, addedAt: addedAt
            ))
        }
        return items
    }

    private func methodKey(_ original: String) -> String {
        var key = original, visited: Set<String> = []
        while let next = index.methodAliases[key], visited.insert(key).inserted { key = next }
        return key
    }

    func listMethodGroups() -> [MethodGroup] { index.methodGroups }

    func createMethodGroup(name: String) throws -> MethodGroup {
        let name = try GroupName.validate(name, existing: index.methodGroups.map(\.name))
        let group = MethodGroup(id: "custom_\(Self.newId())", name: name)
        index.methodGroups.append(group)
        try persistIndex()
        return group
    }

    func renameMethodGroup(id: String, name: String) throws {
        guard let i = index.methodGroups.firstIndex(where: { $0.id == id }) else {
            throw PipelineError("方法分组已不存在。", .internalError)
        }
        index.methodGroups[i].name = try GroupName.validate(name, existing: index.methodGroups.filter { $0.id != id }.map(\.name))
        try persistIndex()
    }

    func deleteMethodGroup(id: String) throws {
        guard index.methodGroups.contains(where: { $0.id == id }) else {
            throw PipelineError("方法分组已不存在。", .internalError)
        }
        let keys = try methodIndex(category: id).map(\.id)
        index.hiddenMethods = Array(Set(index.hiddenMethods).union(keys)).sorted()
        index.methodGroups.removeAll { $0.id == id }
        try persistIndex()
    }

    func moveMethods(keys: [String], groupId: String) throws {
        guard index.methodGroups.contains(where: { $0.id == groupId }) else {
            throw PipelineError("目标方法分组已不存在。", .internalError)
        }
        let items = try methodIndex()
        guard !keys.isEmpty, Set(keys).isSubset(of: Set(items.map(\.id))) else {
            throw PipelineError("方法条目已不存在，请刷新后重试。", .internalError)
        }
        for item in items where keys.contains(item.id) {
            index.methodContent[item.id] = MethodIndexContent(name: item.name, category: groupId, definitionZh: item.definitionZh)
        }
        try persistIndex()
    }

    func editMethod(key: String, name: String, definitionZh: String) throws {
        try Task.checkCancellation()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let item = try methodIndex().first(where: { $0.id == key }) else {
            throw PipelineError("方法名称不能为空，且条目必须仍在索引中。", .internalError)
        }
        index.methodContent[key] = MethodIndexContent(name: title, category: item.category,
            definitionZh: definitionZh.trimmingCharacters(in: .whitespacesAndNewlines))
        try persistIndex()
    }

    func deleteMethod(key: String) throws {
        try Task.checkCancellation()
        guard try methodIndex().contains(where: { $0.id == key }) else {
            throw PipelineError("方法条目已不存在。", .internalError)
        }
        index.hiddenMethods.append(key)
        try persistIndex()
    }

    func mergeMethods(keys: [String], keeping target: String, name: String, definitionZh: String) throws {
        try Task.checkCancellation()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unique = Set(keys)
        let items = try methodIndex()
        guard unique.count == 2, unique.contains(target), !title.isEmpty,
              unique.isSubset(of: Set(items.map(\.id))), let kept = items.first(where: { $0.id == target }) else {
            throw PipelineError("请选择两个仍在索引中的方法，并填写合并后的名称。", .internalError)
        }
        for key in unique where key != target { index.methodAliases[key] = target }
        index.methodContent[target] = MethodIndexContent(name: title, category: kept.category,
            definitionZh: definitionZh.trimmingCharacters(in: .whitespacesAndNewlines))
        try persistIndex()
    }

    // MARK: - 对话持久化

    func chatSessions(paperId: String) throws -> [ChatSession] {
        try LibraryFiles.readJSON(chatFile(paperId), decoder: decoder) ?? []
    }

    func chatSession(paperId: String, sessionId: String) throws -> ChatSession? {
        try chatSessions(paperId: paperId).first { $0.id == sessionId }
    }

    func saveChatSession(paperId: String, session: ChatSession) throws {
        try requirePaper(paperId)
        var sessions = try chatSessions(paperId: paperId)
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.insert(session, at: 0)
        }
        try LibraryFiles.writeJSON(sessions, to: chatFile(paperId), encoder: encoder)
    }

    func renameChatSession(paperId: String, sessionId: String, title: String) throws {
        try requirePaper(paperId)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PipelineError("请填写对话名称。", .internalError) }
        var sessions = try chatSessions(paperId: paperId)
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            throw PipelineError("这段对话已不存在。", .internalError)
        }
        sessions[index].title = title
        try LibraryFiles.writeJSON(sessions, to: chatFile(paperId), encoder: encoder)
    }

    func deleteChatSession(paperId: String, sessionId: String) throws {
        try requirePaper(paperId)
        var sessions = try chatSessions(paperId: paperId)
        sessions.removeAll { $0.id == sessionId }
        try LibraryFiles.writeJSON(sessions, to: chatFile(paperId), encoder: encoder)
    }

    // MARK: - 笔记持久化

    func notes(paperId: String) throws -> [Note] {
        try LibraryFiles.readJSON(notesFile(paperId), decoder: decoder) ?? []
    }

    func addNote(paperId: String, note: Note) throws {
        try requirePaper(paperId)
        var notes = try notes(paperId: paperId)
        notes.insert(note, at: 0)
        try LibraryFiles.writeJSON(notes, to: notesFile(paperId), encoder: encoder)
    }

    // MARK: - Reader annotation sidecar

    func readerAnnotations(paperId: String) throws -> [String: ReaderNodeAnnotation] {
        try requirePaper(paperId)
        return try LibraryFiles.readJSON(paperDir(paperId).appendingPathComponent("reader-annotations.json"), decoder: decoder) ?? [:]
    }

    func saveReaderAnnotations(paperId: String, annotations: [String: ReaderNodeAnnotation]) throws {
        try requirePaper(paperId)
        let validIds = Set(try readBlocks(paperId: paperId).map(\.id))
        let valid = annotations.filter { validIds.contains($0.key) && !$0.value.isEmpty }
        try LibraryFiles.writeJSON(valid, to: paperDir(paperId).appendingPathComponent("reader-annotations.json"), encoder: encoder)
    }

    // MARK: - 分析 sidecar

    func writeAnalysisRaw(paperId: String, name: String, data: [String: Any]) throws {
        try requirePaper(paperId)
        let url = analysesDir(paperId).appendingPathComponent(name)
        let jsonObject = data
        try LibraryFiles.writeJSONAny(jsonObject, to: url)
    }

    // MARK: - 工具

    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// RFC3339 UTC(毫秒 + Z),与后端时间戳列同宽,保证字符串排序稳定。
    static func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    /// 论文块 ID:`b<论文ID前6位>-<四位序号>`,对话引用 [b00xx] 的取值来源。
    static func blockId(paperId: String, order: Int) -> String {
        let prefix = String(paperId.prefix(6))
        return "b\(prefix)-\(String(format: "%04d", order + 1))"
    }

    /// 实体名规范化(对齐 _canonical_key)。
    static func canonicalKey(_ name: String) -> String {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        var output = ""
        for scalar in lowered.unicodeScalars {
            let isAlnum = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
            output.unicodeScalars.append(isAlnum ? scalar : "_")
        }
        return output.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

/// 目录里存在、索引（含回收站）中却没有对应记录的文件。
///
/// 常见来源：永久删除中途失败或崩溃、1.0.x 之前的残留、用户手工拷入。
/// **默认只报告不动手** —— 误删不可逆。
struct OrphanEntry: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case paperDirectory, mineruOutput, analyses, pdf }
    let path: String
    let kind: Kind
    /// 目录属性的粗略体积（不递归统计），仅供用户判断值不值得清理。
    let sizeBytes: Int64
    var id: String { path }
}

// MARK: - DTO 辅助

extension PaperListItem {
    /// 库内新建论文的默认记录;非空字段全部给后端语义一致的空值。
    static func empty(id: String) -> PaperListItem {
        PaperListItem(
            id: id, title: "", titleZh: "", authors: [], year: nil,
            domainTags: [], status: "uploaded", projectId: nil,
            sourceType: "pdf_upload", originalFileName: "", createdAt: PaperLibrary.now(),
            lastOpenedAt: nil, tldr: "", narrativeSummary: "", contributions: [],
            difficultyEstimate: "", venue: "", errorMessage: "", errorCode: nil,
            doi: nil, arxivId: nil, metaSource: MetaSource.local
        )
    }
}
