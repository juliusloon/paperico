import XCTest
@testable import PapericoCore

final class LibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func pdf(_ value: String = "test") -> Data { Data("%PDF-1.7\n\(value)".utf8) }

    func testSearchFindsBothTitlesAndFilenameWhileKeepingProjectFilter() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let project = try await library.createProject(name: "Chemistry", description: "")
        let paper = try await library.importPDF(fileData: pdf("first"), fileName: "activity-cliff.pdf", projectId: project.id)
        _ = try await library.importPDF(fileData: pdf("second"), fileName: "other.pdf", projectId: nil)
        try await library.updatePaper { record in
            if record.id == paper.id {
                record.title = "Graph learning for molecules"
                record.titleZh = "活性悬崖感知与图学习"
            }
        }
        let original = await library.listPapers(q: "  GRAPH  ")
        let translated = await library.listPapers(q: "活性悬崖")
        let filename = await library.listPapers(q: "ACTIVITY-CLIFF.PDF")
        let outsideProject = await library.listPapers(projectId: project.id, q: "other")
        let empty = await library.listPapers(q: " ")
        XCTAssertEqual(original.map(\.id), [paper.id])
        XCTAssertEqual(translated.map(\.id), [paper.id])
        XCTAssertEqual(filename.map(\.id), [paper.id])
        XCTAssertTrue(outsideProject.isEmpty)
        XCTAssertEqual(empty.count, 2)
    }

    func testConcurrentImportsSurviveReload() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                let data = pdf("\(i)")
                group.addTask { _ = try await library.importPDF(fileData: data, fileName: "\(i).pdf", projectId: nil) }
            }
            try await group.waitForAll()
        }
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let papers = await reopened.listPapers()
        XCTAssertEqual(papers.count, 30)
        XCTAssertEqual(Set(papers.map(\.id)).count, 30)
    }

    func testFailedPaperStillDeduplicates() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf(), fileName: "test.pdf", projectId: nil)
        try await library.setStatus(paperId: paper.id, status: "error")
        do {
            _ = try await library.importPDF(fileData: pdf(), fileName: "again.pdf", projectId: nil)
            XCTFail("Duplicate import must be rejected even after an API failure")
        } catch { XCTAssertEqual((error as? PipelineError)?.errorCode, .duplicatePaper) }
    }

    func testTrashPreservesPDFChatAndNotesAndRestoresWithoutDeletedProject() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let project = try await library.createProject(name: "Chemistry", description: "")
        let paper = try await library.importPDF(fileData: pdf(), fileName: "test.pdf", projectId: project.id)
        let session = ChatSession(id: "s1", paperId: paper.id, title: "Question", messages: [], createdAt: PaperLibrary.now())
        let note = Note(id: "n1", paperId: paper.id, title: "Notes", markdownContent: "# Evidence", createdAt: PaperLibrary.now(), updatedAt: PaperLibrary.now())
        try await library.saveChatSession(paperId: paper.id, session: session)
        try await library.addNote(paperId: paper.id, note: note)
        try await library.deletePaper(id: paper.id)
        let active = await library.listPapers()
        XCTAssertTrue(active.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pdfs/\(paper.id).pdf")), pdf())
        try await library.deleteProject(id: project.id)
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let trash = await reopened.listTrash()
        XCTAssertEqual(trash.count, 1)
        try await reopened.restorePaper(id: paper.id)
        let detail = try await reopened.paperDetail(id: paper.id)
        let sessions = try await reopened.chatSessions(paperId: paper.id)
        let notes = try await reopened.notes(paperId: paper.id)
        XCTAssertNil(detail.paper.projectId)
        XCTAssertEqual(sessions, [session])
        XCTAssertEqual(notes, [note])
    }

    func testTrashBlocksLateWritesAndDuplicateImport() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf(), fileName: "test.pdf", projectId: nil)
        try await library.deletePaper(id: paper.id)
        do {
            try await library.writeBlocks(paperId: paper.id, blocks: [])
            XCTFail("An old task must not write to a deleted paper")
        } catch { XCTAssertTrue(error is PipelineError) }
        do {
            _ = try await library.importPDF(fileData: pdf(), fileName: "test.pdf", projectId: nil)
            XCTFail("Offer restore instead of duplicating trashed content")
        } catch { XCTAssertEqual((error as? PipelineError)?.errorCode, .duplicatePaper) }
    }

    func testConcurrentSessionSavesAreNotLost() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf(), fileName: "test.pdf", projectId: nil)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<25 {
                let session = ChatSession(id: "s\(i)", paperId: paper.id, title: "Question", messages: [], createdAt: PaperLibrary.now())
                group.addTask { try await library.saveChatSession(paperId: paper.id, session: session) }
            }
            try await group.waitForAll()
        }
        let sessions = try await library.chatSessions(paperId: paper.id)
        XCTAssertEqual(sessions.count, 25)
    }

    func testCorruptIndexIsNotOverwritten() async throws {
        let file = root.appendingPathComponent("library.json")
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: file)
        do { try await PaperLibrary(root: root).load(); XCTFail("Corrupt index must be surfaced") }
        catch { XCTAssertEqual((error as? PipelineError)?.errorCode, .storageFailed) }
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testFutureSchemaIsNotOverwritten() async throws {
        let file = root.appendingPathComponent("library.json")
        let data = Data(#"{"schema_version":99,"projects":[],"papers":[]}"#.utf8)
        try data.write(to: file)
        do { try await PaperLibrary(root: root).load(); XCTFail("Unknown schema must be rejected") }
        catch { XCTAssertEqual((error as? PipelineError)?.errorCode, .storageFailed) }
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testUnversionedIndexAndInterruptedWorkMigrate() async throws {
        var paper = PaperListItem.empty(id: "old-paper")
        paper.status = "analyzing"
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object: [String: Any] = ["projects": [], "papers": [try JSONSerialization.jsonObject(with: encoder.encode(paper))], "source_url_by_paper_id": [paper.id: "https://example.test/paper.pdf"]]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("library.json"))
        let library = PaperLibrary(root: root)
        try await library.load()
        let loaded = await library.paper(id: paper.id)
        let source = await library.sourceURL(paperId: paper.id)
        XCTAssertEqual(loaded?.status, "error")
        XCTAssertEqual(loaded?.errorCode, ErrorCode.interruptedByRestart.rawValue)
        XCTAssertEqual(source, "https://example.test/paper.pdf")
    }

    func testFailedIndexWriteRollsBackMemory() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library.json"), withIntermediateDirectories: false)
        do { _ = try await library.createProject(name: "Unwritten", description: ""); XCTFail("Write must fail") }
        catch { XCTAssertEqual((error as? PipelineError)?.errorCode, .storageFailed) }
        let projects = await library.listProjects()
        XCTAssertTrue(projects.isEmpty)
    }

    func testAssetPathsStayInsideLibrary() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        let layout = LibraryLayout(root: root)
        XCTAssertNil(layout.fileURL(forRelativePath: "../\(outside.lastPathComponent)"))
        XCTAssertNil(layout.fileURL(forRelativePath: outside.path))
        XCTAssertNil(layout.fileURL(forRelativePath: "link"))
    }
}
