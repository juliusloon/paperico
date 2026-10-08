import Foundation
import Observation

// MARK: - PapersStore

struct PapersFilter: Hashable, Sendable {
    var projectId: String?
    var q: String?
}

@MainActor
@Observable
final class PapersStore {
    private let library: PaperLibrary
    private let pipeline: PaperPipeline

    var papers: [PaperListItem] = []
    var loading = false
    var error = ""
    var filter = PapersFilter()

    init(library: PaperLibrary, pipeline: PaperPipeline) {
        self.library = library
        self.pipeline = pipeline
    }

    func fetch(_ newFilter: PapersFilter? = nil) async {
        loading = true
        error = ""
        if let newFilter { filter = newFilter }
        papers = await library.listPapers(projectId: filter.projectId, q: filter.q)
        loading = false
    }

    func upload(fileData: Data, fileName: String, projectId: String?) async throws -> PaperListItem {
        let paper = try await library.importPDF(fileData: fileData, fileName: fileName, projectId: projectId)
        papers.insert(paper, at: 0)
        // 入库即启动 MinerU 解析 → 单次全文分析管线。
        if pipeline.isConfigured { pipeline.startProcessing(paperId: paper.id) }
        return paper
    }

    func importZotero(folder: URL, projectId: String?) async throws -> ZoteroImport.Report {
        let report = try await ZoteroImport.run(folder: folder, projectId: projectId, library: library)
        // All authority fields are already persisted before any analysis starts.
        if pipeline.isConfigured { report.imported.forEach { pipeline.startProcessing(paperId: $0.id) } }
        await fetch()
        return report
    }

    func movePapers(paperIds: [String], projectId: String?) async throws {
        guard !paperIds.isEmpty else { return }
        _ = try await library.movePapers(paperIds: paperIds, projectId: projectId)
        let selected = Set(paperIds)
        if let current = filter.projectId, !current.isEmpty, current != projectId {
            papers.removeAll { selected.contains($0.id) }
        } else {
            papers = papers.map { paper in
                var p = paper
                if selected.contains(p.id) { p.projectId = projectId }
                return p
            }
        }
    }

    func renamePaper(id: String, title: String) async throws {
        let updated = try await library.renamePaper(id: id, title: title)
        papers = papers.map { $0.id == id ? updated : $0 }
    }

    func recognizeMetadata(id: String) async throws -> MetadataRecognition.Outcome {
        let outcome = try await pipeline.runMetadataRecognition(paperId: id)
        await fetch()
        return outcome
    }

    func editMetadata(id: String, metadata: PaperMetadata.Metadata) async throws {
        let updated = try await library.editMetadata(id: id, metadata: metadata)
        papers = papers.map { $0.id == id ? updated : $0 }
    }

    func deletePaper(id: String) async throws {
        await pipeline.cancel(paperId: id)
        try await library.deletePaper(id: id)
        papers.removeAll { $0.id == id }
    }

    func setFilter(_ f: PapersFilter) { filter = f }
}
