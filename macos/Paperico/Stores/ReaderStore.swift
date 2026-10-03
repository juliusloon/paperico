import Foundation
import Observation

// MARK: - ReaderStore (mirrors useReaderStore)

enum BilingualMode: String, Hashable, CaseIterable {
    case original, translation, bilingual
}

/// T2.3: a pending "locate this block on the PDF canvas" request; the token
/// increments so re-clicking the same block re-triggers the jump.
struct PendingPdfFocus: Equatable {
    var blockId: String
    var token: Int
}

@MainActor
@Observable
final class ReaderStore {
    private let library: PaperLibrary

    var paper: PaperDetail?
    var error = ""
    var loading = false

    // UI state (mirrors the store fields)
    var bilingualMode: BilingualMode = .bilingual
    var fontSize: CGFloat = 18
    var leftPanelCollapsed = false
    var activeBlockId: String?
    var highlightedEntities: [String] = []
    var attachedContext: [AttachedContext] = []

    // Native scroll coordination
    var pendingScrollTarget: String?
    var pendingScrollAnchorCentered = false
    // Mirrored from ReadingArea so chat chips / MetaCard / outline jumps know
    // whether the PDF canvas is the active surface.
    var viewMode: ReaderViewMode = .text
    var pendingPdfFocus: PendingPdfFocus?

    var annotationDraft = ReaderAnnotationDraft()
    var savingAnnotations = false
    var annotationsError = ""
    var editingAnnotation = false
    var nodeAnnotations: [String: ReaderNodeAnnotation] { annotationDraft.values }
    private struct PendingAnnotation {
        var blockId: String
        var field: String
        var text: String
    }
    private var pendingAnnotation: PendingAnnotation?
    var hasUnsavedAnnotations: Bool {
        if annotationDraft.isDirty { return true }
        guard let pendingAnnotation else { return false }
        let text = pendingAnnotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingAnnotation.field == "note" { return text != (nodeAnnotations[pendingAnnotation.blockId]?.note ?? "") }
        return !text.isEmpty && text != outlineEntries.first(where: { $0.blockId == pendingAnnotation.blockId })?.title
    }
    func stageAnnotation(blockId: String, field: String, text: String) {
        guard outlineEntries.contains(where: { $0.blockId == blockId }), ["note", "title"].contains(field) else { return }
        pendingAnnotation = PendingAnnotation(blockId: blockId, field: field, text: text)
    }
    func cancelPendingAnnotation() { pendingAnnotation = nil }
    func commitPendingAnnotation() {
        guard let pendingAnnotation else { return }
        self.pendingAnnotation = nil
        if pendingAnnotation.field == "note" { editNodeNote(blockId: pendingAnnotation.blockId, note: pendingAnnotation.text) }
        else { editOutline(blockId: pendingAnnotation.blockId, title: pendingAnnotation.text) }
    }
    func discardAnnotations() { pendingAnnotation = nil; editingAnnotation = false; annotationDraft.discard() }
    var outlineEntries: [PaperOutlineEntry] {
        PaperOutline.entries(paper?.blocks ?? []).map { entry in
            PaperOutlineEntry(blockId: entry.blockId, level: entry.level, heading: entry.heading,
                              title: nodeAnnotations[entry.blockId]?.title ?? entry.title, parentBlockId: entry.parentBlockId)
        }
    }

    func editOutline(blockId: String, title: String) {
        guard let entry = PaperOutline.entries(paper?.blocks ?? []).first(where: { $0.blockId == blockId }) else { return }
        var value = nodeAnnotations[blockId] ?? ReaderNodeAnnotation()
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !trimmed.isEmpty else { return }
        value.title = trimmed == entry.title ? nil : trimmed
        annotationDraft.set(value, for: blockId)
    }

    func editNodeNote(blockId: String, note: String) {
        guard outlineEntries.contains(where: { $0.blockId == blockId }) else { return }
        var value = nodeAnnotations[blockId] ?? ReaderNodeAnnotation()
        value.note = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20000))
        annotationDraft.set(value, for: blockId)
    }

    func saveAnnotations() async -> Bool {
        guard let id = paper?.paper.id, !savingAnnotations else { return false }
        commitPendingAnnotation()
        let snapshot = nodeAnnotations
        savingAnnotations = true; annotationsError = ""
        defer { savingAnnotations = false }
        do {
            try await library.saveReaderAnnotations(paperId: id, annotations: snapshot)
            if paper?.paper.id == id { annotationDraft.didSave(snapshot) }
            return true
        } catch {
            annotationsError = ApiFailure.wrap(error).localizedDescription
            return false
        }
    }

    private var readerRequestVersion = 0

    init(library: PaperLibrary) {
        self.library = library
    }

    func fetchPaper(id: String) async {
        readerRequestVersion += 1
        let version = readerRequestVersion
        let startedAt = ReaderPerf.start("reader.fetchPaper")
        loading = true
        paper = nil
        error = ""
        attachedContext = []
        activeBlockId = nil
        pendingPdfFocus = nil
        pendingAnnotation = nil
        annotationDraft.load([:])
        annotationsError = ""
        // 切换论文时释放上一篇正文产生的解析缓存(受 countLimit 兜底,这里是主动回收)。
        PaperMarkdown.clearCache()
        do {
            let detail = try await library.paperDetail(id: id)
            let annotations = try await library.readerAnnotations(paperId: id)
            if version == readerRequestVersion {
                paper = detail
                annotationDraft.load(annotations)
                loading = false
            }
            ReaderPerf.end("reader.fetchPaper", startedAt: startedAt)
        } catch {
            if version == readerRequestVersion {
                loading = false
                self.error = ApiFailure.wrap(error).errorDescription ?? "论文加载失败，请重试。"
            }
            ReaderPerf.end("reader.fetchPaper", startedAt: startedAt)
        }
    }

    func refreshPaper(id: String) async {
        let version = readerRequestVersion
        let startedAt = ReaderPerf.start("reader.refreshPaper")
        guard let detail = try? await library.paperDetail(id: id, markOpened: false) else { return }
        if version == readerRequestVersion, paper?.paper.id == id {
            paper = detail
        }
        ReaderPerf.end("reader.refreshPaper", startedAt: startedAt)
    }

    /// 只更新 status / 错误信息,不整篇重载。
    /// 处理阶段的轮询用它刷新阶段文案,避免周期性把整篇 180+ 个 block 作废重建。
    func applyStatus(_ status: PaperStatusOut) {
        guard var detail = paper, detail.paper.id == status.id else { return }
        guard detail.paper.status != status.status
                || detail.paper.errorMessage != status.errorMessage
                || detail.paper.errorCode != status.errorCode else { return }
        detail.paper.status = status.status
        detail.paper.errorMessage = status.errorMessage
        detail.paper.errorCode = status.errorCode
        paper = detail
    }

    func setBilingualMode(_ mode: BilingualMode) {
        bilingualMode = mode
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = min(23, max(13, size))
    }

    func toggleLeftPanel() {
        leftPanelCollapsed.toggle()
    }

    func setActiveBlock(_ id: String?) {
        activeBlockId = id
    }

    func highlightEntities(_ ids: [String]) {
        highlightedEntities = ids
    }

    func addAttachedContext(_ ctx: AttachedContext) {
        let duplicate = attachedContext.contains { item in
            item.type == ctx.type
                && item.refEntityId == ctx.refEntityId
                && item.refBlockId == ctx.refBlockId
                && item.snippet == ctx.snippet
        }
        if !duplicate {
            attachedContext.append(ctx)
        }
    }

    func removeAttachedContext(at index: Int) {
        guard attachedContext.indices.contains(index) else { return }
        attachedContext.remove(at: index)
    }

    func clearAttachedContext() {
        attachedContext = []
    }

    // MARK: scroll coordination

    /// Scrolls the reading area to a block.
    /// In PDF mode the jump is redirected to the PDF canvas (T2.3).
    func scrollToBlock(_ blockId: String, centered: Bool = false) {
        activeBlockId = blockId
        if viewMode == .pdf {
            requestPdfFocus(blockId)
            return
        }
        pendingScrollTarget = blockId
        pendingScrollAnchorCentered = centered
    }

    func setViewMode(_ mode: ReaderViewMode) {
        viewMode = mode
    }

    func requestPdfFocus(_ blockId: String) {
        pendingPdfFocus = PendingPdfFocus(blockId: blockId, token: (pendingPdfFocus?.token ?? 0) + 1)
    }

    func consumeScrollTarget() {
        pendingScrollTarget = nil
    }
}
