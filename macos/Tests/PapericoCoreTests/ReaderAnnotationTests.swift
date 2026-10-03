import XCTest
@testable import PapericoCore

final class ReaderAnnotationTests: XCTestCase {
    func testUndoRedoAndDiscardKeepSavedVersion() {
        var draft = ReaderAnnotationDraft()
        let original = ReaderNodeAnnotation(title: "已保存", note: "**证据**")
        draft.load(["b1": original])
        draft.set(ReaderNodeAnnotation(title: "修订", note: "==重点=="), for: "b1")
        XCTAssertTrue(draft.isDirty)
        draft.undo()
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.values["b1"], original)
        draft.redo()
        XCTAssertTrue(draft.isDirty)
        draft.discard()
        XCTAssertEqual(draft.values, ["b1": original])
        XCTAssertFalse(draft.canUndo)
        XCTAssertFalse(draft.canRedo)
    }

    func testSavingSnapshotDoesNotMarkNewerEditsAsSaved() {
        var draft = ReaderAnnotationDraft()
        draft.set(ReaderNodeAnnotation(title: "第一版"), for: "b1")
        let snapshot = draft.values
        draft.set(ReaderNodeAnnotation(title: "第二版"), for: "b1")
        draft.didSave(snapshot)
        XCTAssertTrue(draft.isDirty)
        draft.undo()
        XCTAssertFalse(draft.isDirty)
        XCTAssertEqual(draft.values["b1"]?.title, "第一版")
    }

    func testClearingAnnotationAndEditingAfterUndoDropsRedo() {
        var draft = ReaderAnnotationDraft()
        draft.set(ReaderNodeAnnotation(), for: "empty")
        XCTAssertFalse(draft.canUndo)
        draft.set(ReaderNodeAnnotation(note: "笔记"), for: "b1")
        draft.set(ReaderNodeAnnotation(), for: "b1")
        XCTAssertTrue(draft.values.isEmpty)
        draft.undo()
        XCTAssertEqual(draft.values["b1"]?.note, "笔记")
        draft.set(ReaderNodeAnnotation(note: "修改"), for: "b1")
        XCTAssertFalse(draft.canRedo)
    }

    func testSidecarSurvivesReopenWithoutChangingGeneratedBlocks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\ntest".utf8), fileName: "test.pdf", projectId: nil)
        let block = Block(id: "b1", order: 0, kind: "paragraph", pageIdx: 0, bbox: nil, sectionTitle: "",
                          textOriginal: "Evidence", textZh: "证据", oneLiner: "系统摘要", keywords: [], roleInNarrative: "发现",
                          imagePath: "", captionOriginal: "", captionZh: "", figureType: "", coreTakeaways: [],
                          dataReadingNotes: "", tableHtml: "", latex: "", plainExplanation: "", entityRefs: [])
        try await library.writeBlocks(paperId: paper.id, blocks: [block])
        let annotation = ReaderNodeAnnotation(title: "我的理解", note: "**重点** 与 ==证据==")
        try await library.saveReaderAnnotations(paperId: paper.id, annotations: ["b1": annotation, "unknown": annotation])
        try await library.deletePaper(id: paper.id)
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        try await reopened.restorePaper(id: paper.id)
        let saved = try await reopened.readerAnnotations(paperId: paper.id)
        let blocks = try await reopened.readBlocks(paperId: paper.id)
        XCTAssertEqual(saved, ["b1": annotation])
        XCTAssertEqual(blocks, [block])
    }
}
