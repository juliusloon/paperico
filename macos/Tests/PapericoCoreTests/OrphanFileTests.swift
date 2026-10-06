import XCTest
@testable import PapericoCore

/// T7: directories that exist on disk but are referenced by nothing in the index.
/// The report is read-only by default — deletion requires explicit confirmation.
final class OrphanFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func pdf(_ value: String = "orphan") -> Data { Data("%PDF-1.7\n\(value)".utf8) }

    private func makeDirectory(_ relative: String, file: String = "data.json") throws {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: url.appendingPathComponent(file))
    }

    func testLeftoverDirectoriesAreReported() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        try makeDirectory("papers/deadbeef1234")
        try makeDirectory("mineru_output/deadbeef1234")
        try makeDirectory("analyses/cafebabe5678")

        let orphans = await library.orphanFiles()
        XCTAssertEqual(orphans.map(\.path), ["analyses/cafebabe5678", "mineru_output/deadbeef1234", "papers/deadbeef1234"])
        XCTAssertEqual(Set(orphans.map(\.kind)), [.analyses, .mineruOutput, .paperDirectory])
    }

    func testReferencedPapersAndTrashedPapersAreNotOrphans() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf("live"), fileName: "live.pdf", projectId: nil)
        let trashed = try await library.importPDF(fileData: pdf("gone"), fileName: "gone.pdf", projectId: nil)
        for id in [paper.id, trashed.id] {
            try makeDirectory("papers/\(id)")
            try makeDirectory("mineru_output/\(id)")
        }
        // A trashed paper keeps its files until permanent deletion — not an orphan.
        try await library.deletePaper(id: trashed.id)

        let orphans = await library.orphanFiles()
        XCTAssertTrue(orphans.isEmpty, "Unexpected orphans: \(orphans.map(\.path))")
    }

    func testOrphanPdfIsReported() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pdfs"), withIntermediateDirectories: true)
        try pdf("stray").write(to: root.appendingPathComponent("pdfs/strayid99.pdf"))
        let orphans = await library.orphanFiles()
        XCTAssertEqual(orphans.map(\.path), ["pdfs/strayid99.pdf"])
        XCTAssertEqual(orphans.first?.kind, .pdf)
    }

    /// The core safety property: scanning changes nothing.
    func testReportingNeverDeletesAnything() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        try makeDirectory("papers/deadbeef1234")
        _ = await library.orphanFiles()
        _ = await library.orphanFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers/deadbeef1234").path))
        let orphans = await library.orphanFiles()
        XCTAssertEqual(orphans.count, 1)
    }

    func testExplicitDeletionRemovesOnlyTheSelectedEntry() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        try makeDirectory("papers/deadbeef1234")
        try makeDirectory("papers/cafebabe5678")
        let candidates = await library.orphanFiles()
        let target = try XCTUnwrap(candidates.first { $0.path == "papers/deadbeef1234" })

        try await library.deleteOrphan(target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers/deadbeef1234").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("papers/cafebabe5678").path))
        let remaining = await library.orphanFiles()
        XCTAssertEqual(remaining.map(\.path), ["papers/cafebabe5678"])
    }

    func testIndexIsUnaffectedByOrphanCleanup() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf("live"), fileName: "live.pdf", projectId: nil)
        try makeDirectory("papers/deadbeef1234")
        let before = try Data(contentsOf: root.appendingPathComponent("library.json"))

        let candidates = await library.orphanFiles()
        let target = try XCTUnwrap(candidates.first)
        try await library.deleteOrphan(target)

        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before,
                       "Deleting an unreferenced directory must not rewrite the index")
        let papers = await library.listPapers()
        XCTAssertEqual(papers.map(\.id), [paper.id])
    }

    /// A stale entry (already removed by hand) must fail loudly rather than silently pass.
    func testStaleOrphanEntryIsRejected() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let stale = OrphanEntry(path: "papers/neverexisted", kind: .paperDirectory, sizeBytes: 0)
        do {
            try await library.deleteOrphan(stale)
            XCTFail("A stale entry must be reported, not silently accepted")
        } catch {
            XCTAssertEqual((error as? PipelineError)?.errorCode, .storageFailed)
        }
    }

    func testSizeIsReportedWithoutRecursing() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        try makeDirectory("papers/deadbeef1234", file: "blocks.json")
        let orphans = await library.orphanFiles()
        let entry = try XCTUnwrap(orphans.first)
        // Directory size uses the attribute, not a recursive walk: 0 for directories.
        XCTAssertEqual(entry.sizeBytes, 0)
        XCTAssertGreaterThanOrEqual(orphans.count, 1)
    }
}