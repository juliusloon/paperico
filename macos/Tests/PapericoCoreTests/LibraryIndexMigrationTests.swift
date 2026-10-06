import XCTest
@testable import PapericoCore

/// T2/T6: the on-disk contract. A v1 `library.json` (and the unversioned variant
/// written during the Web → native migration) must keep decoding, take defaults for
/// fields added in v2, and never silently drop data. Fixtures contain no paper text.
final class LibraryIndexMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// A v1 record: every field that existed before the v2 metadata columns.
    private func v1Paper(id: String = "paper-v1") -> [String: Any] {
        [
            "id": id, "title": "A Preprint", "title_zh": "", "authors": [],
            "domain_tags": [], "status": "ready", "source_type": "pdf_upload",
            "original_file_name": "preprint.pdf", "created_at": "2026-09-01T10:00:00.000Z",
            "tldr": "", "narrative_summary": "", "contributions": [],
            "difficulty_estimate": "", "venue": "", "error_message": ""
        ]
    }

    private func writeIndex(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: root.appendingPathComponent("library.json"))
    }

    private func readStoredVersion() throws -> Int {
        let data = try Data(contentsOf: root.appendingPathComponent("library.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["schema_version"] as? Int ?? 1
    }

    // MARK: - Migration path

    func testV1IndexMigratesAndTakesDefaultsForNewFields() async throws {
        try writeIndex(["schema_version": 1, "projects": [], "papers": [v1Paper()]])
        let library = PaperLibrary(root: root)
        try await library.load()
        let loaded = await library.paper(id: "paper-v1")
        let paper = try XCTUnwrap(loaded)
        XCTAssertEqual(paper.title, "A Preprint")
        XCTAssertNil(paper.doi)
        XCTAssertNil(paper.arxivId)
        XCTAssertEqual(paper.metaSource, MetaSource.local)
        // The migration is written back so the next launch does not repeat it.
        XCTAssertEqual(try readStoredVersion(), LibraryIndexMigrations.current)
    }

    func testUnversionedIndexStillDecodesAndMigrates() async throws {
        try writeIndex(["projects": [], "papers": [v1Paper(id: "paper-unversioned")]])
        let library = PaperLibrary(root: root)
        try await library.load()
        let loaded = await library.paper(id: "paper-unversioned")
        let paper = try XCTUnwrap(loaded)
        XCTAssertEqual(paper.originalFileName, "preprint.pdf")
        XCTAssertEqual(paper.metaSource, MetaSource.local)
        XCTAssertEqual(try readStoredVersion(), LibraryIndexMigrations.current)
    }

    func testMigrationIsIdempotent() throws {
        var index = LibraryIndex()
        var record = PaperListItem.empty(id: "paper-v1")
        record.doi = "10.1234/abc"
        record.arxivId = "2501.01234"
        record.metaSource = MetaSource.auto
        index.papers = [record]
        index.schemaVersion = 1

        try LibraryIndexMigrations.migrate(&index, from: 1)
        let once = index
        try LibraryIndexMigrations.migrate(&index, from: index.schemaVersion)
        try LibraryIndexMigrations.migrate(&index, from: 1)
        XCTAssertEqual(index.papers, once.papers)
        XCTAssertEqual(index.schemaVersion, LibraryIndexMigrations.current)
    }

    // MARK: - Guards

    func testFutureSchemaIsRejectedAndFileUntouched() async throws {
        try writeIndex(["schema_version": 99, "projects": [], "papers": [v1Paper()]])
        let before = try Data(contentsOf: root.appendingPathComponent("library.json"))
        do {
            try await PaperLibrary(root: root).load()
            XCTFail("A newer library must be refused, not downgraded")
        } catch {
            XCTAssertEqual((error as? PipelineError)?.errorCode, .storageFailed)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library.json")), before)
    }

    func testMigrationBacksUpTheOriginalIndex() async throws {
        try writeIndex(["schema_version": 1, "projects": [], "papers": [v1Paper()]])
        try await PaperLibrary(root: root).load()
        let backups = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".bak-v1-") }
        XCTAssertEqual(backups.count, 1, "Expected exactly one pre-migration backup")
        let backup = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(backups[0]))
        ) as? [String: Any]
        XCTAssertEqual(backup?["schema_version"] as? Int, 1)
    }

    func testCurrentSchemaIndexIsNotBackedUpOnEveryLaunch() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        _ = try await library.importPDF(fileData: Data("%PDF-1.7\nv2".utf8), fileName: "v2.pdf", projectId: nil)
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let backups = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".bak-v") }
        XCTAssertTrue(backups.isEmpty, "An up-to-date library must not produce backups")
    }

    func testMigratedRecordKeepsRoundTrippingThroughDisk() async throws {
        try writeIndex(["schema_version": 1, "projects": [], "papers": [v1Paper()]])
        let library = PaperLibrary(root: root)
        try await library.load()
        try await library.updatePaper { record in
            guard record.id == "paper-v1" else { return }
            record.doi = "10.5555/xyz"
            record.arxivId = "2502.00002"
            record.metaSource = MetaSource.auto
        }
        let reopened = PaperLibrary(root: root)
        try await reopened.load()
        let loaded = await reopened.paper(id: "paper-v1")
        let paper = try XCTUnwrap(loaded)
        XCTAssertEqual(paper.doi, "10.5555/xyz")
        XCTAssertEqual(paper.arxivId, "2502.00002")
        XCTAssertEqual(paper.metaSource, MetaSource.auto)
    }
}