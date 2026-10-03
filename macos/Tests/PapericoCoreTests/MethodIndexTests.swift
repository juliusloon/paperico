import XCTest
@testable import PapericoCore

final class MethodIndexTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func fixture() async throws -> (PaperLibrary, String, String) {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: Data("%PDF-1.7\nfirst".utf8), fileName: "first.pdf", projectId: nil)
        let second = try await library.importPDF(fileData: Data("%PDF-1.7\nsecond".utf8), fileName: "second.pdf", projectId: nil)
        try await library.writeEntities(paperId: first.id, entities: [
            MethodEntity(id: "a", canonicalKey: "alpha", name: "Alpha", category: "model", definitionZh: "第一项", blockRefs: ["b1", "b2"]),
            MethodEntity(id: "b", canonicalKey: "beta", name: "Beta", category: "tool", definitionZh: "第二项", blockRefs: ["b2", "b3"])
        ])
        try await library.writeEntities(paperId: second.id, entities: [
            MethodEntity(id: "c", canonicalKey: "beta", name: "Beta", category: "tool", definitionZh: "第二项", blockRefs: ["b1"])
        ])
        return (library, first.id, second.id)
    }

    func testEditingPersistsAndSearchUsesEditedNameWithoutChangingPaperEvidence() async throws {
        let (library, first, _) = try await fixture()
        let initial = try await library.methodIndex()
        let timestamp = initial.first { $0.id == "alpha" }?.addedAt
        XCTAssertNotNil(timestamp)
        try await library.editMethod(key: "alpha", name: "  Gamma  ", definitionZh: "新说明")
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let edited = try await reopened.methodIndex(q: " GAMMA ")
        XCTAssertEqual(edited.count, 1)
        XCTAssertEqual(edited.first?.name, "Gamma")
        XCTAssertEqual(edited.first?.definitionZh, "新说明")
        XCTAssertEqual(edited.first?.addedAt, timestamp)
        let evidence = try await reopened.readEntities(paperId: first)
        XCTAssertEqual(evidence.first?.name, "Alpha")
    }

    func testMergeKeepingSecondUnionsReferencesAcrossPapersAndSurvivesReload() async throws {
        let (library, first, second) = try await fixture()
        try await library.mergeMethods(keys: ["alpha", "beta"], keeping: "beta", name: "Beta", definitionZh: "第二项")
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let items = try await reopened.methodIndex(category: "tool")
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item.id, "beta")
        XCTAssertEqual(item.name, "Beta")
        XCTAssertEqual(item.definitionZh, "第二项")
        XCTAssertEqual(item.papers.count, 2)
        XCTAssertEqual(item.papers.first { $0.paperId == first }?.blockIds, ["b1", "b2", "b3"])
        XCTAssertEqual(item.papers.first { $0.paperId == second }?.blockIds, ["b1"])
        let originalCategory = try await reopened.methodIndex(category: "model")
        XCTAssertTrue(originalCategory.isEmpty)
    }

    func testMergeKeepingFirstAcceptsRewrittenContentAndDeletionHidesBothAliases() async throws {
        let (library, first, _) = try await fixture()
        try await library.mergeMethods(keys: ["alpha", "beta"], keeping: "alpha", name: "组合方法", definitionZh: "重新编写的说明")
        let merged = try await library.methodIndex()
        XCTAssertEqual(merged.map(\.name), ["组合方法"])
        try await library.deleteMethod(key: "alpha")
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let visible = try await reopened.methodIndex()
        let evidence = try await reopened.readEntities(paperId: first)
        XCTAssertTrue(visible.isEmpty)
        XCTAssertEqual(evidence.count, 2)
    }

    func testInvalidMergeAndEmptyEditDoNotMutateIndex() async throws {
        let (library, _, _) = try await fixture()
        for keys in [["alpha", "alpha"], ["alpha", "missing"]] {
            do {
                try await library.mergeMethods(keys: keys, keeping: "alpha", name: "Invalid", definitionZh: "")
                XCTFail("Invalid pair must be rejected")
            } catch { XCTAssertTrue(error is PipelineError) }
        }
        do {
            try await library.editMethod(key: "alpha", name: " \n", definitionZh: "")
            XCTFail("Blank name must be rejected")
        } catch { XCTAssertTrue(error is PipelineError) }
        let items = try await library.methodIndex()
        XCTAssertEqual(Set(items.map(\.name)), ["Alpha", "Beta"])
    }

    func testFailedMergeWriteRollsBackAliasesAndContent() async throws {
        let (library, _, _) = try await fixture()
        let file = root.appendingPathComponent("library.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        do {
            try await library.mergeMethods(keys: ["alpha", "beta"], keeping: "alpha", name: "Merged", definitionZh: "")
            XCTFail("Index write must fail")
        } catch { XCTAssertEqual((error as? PipelineError)?.errorCode, .storageFailed) }
        let items = try await library.methodIndex()
        XCTAssertEqual(Set(items.map(\.name)), ["Alpha", "Beta"])
    }
}
