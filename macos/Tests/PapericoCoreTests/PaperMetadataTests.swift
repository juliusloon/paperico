import XCTest
@testable import PapericoCore

/// Mocks Crossref / arXiv Atom and the "network is down" case.
private final class MetadataProtocol: URLProtocol {
    struct Reply { let status: Int; let body: String; let delay: TimeInterval }
    nonisolated(unsafe) static var reply = Reply(status: 200, body: "{}", delay: 0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.reply
        let client = self.client
        let stub = self
        let url = request.url!
        let work = {
            let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(stub, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(stub)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work)
        } else {
            work()
        }
    }
    override func stopLoading() {}
}

final class PaperMetadataTests: XCTestCase {
    private var root: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataProtocol.self]
        session = URLSession(configuration: config)
        MetadataProtocol.reply = .init(status: 200, body: "{}", delay: 0)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try FileManager.default.removeItem(at: root)
    }

    private func pdf(_ value: String = "meta") -> Data { Data("%PDF-1.7\n\(value)".utf8) }

    private func block(_ order: Int, kind: String = "paragraph", section: String = "", text: String) -> Block {
        Block(id: PaperLibrary.blockId(paperId: "paper-meta", order: order), order: order, kind: kind,
              pageIdx: order, bbox: nil, sectionTitle: section, textOriginal: text, textZh: "",
              oneLiner: "", keywords: [], roleInNarrative: "", imagePath: "", captionOriginal: "",
              captionZh: "", figureType: "", coreTakeaways: [], dataReadingNotes: "", tableHtml: "",
              latex: "", plainExplanation: "", entityRefs: [])
    }

    private let crossrefBody = """
    {"status":"ok","message":{
      "title":["Attention Is All You Need"],
      "author":[{"given":"Ashish","family":"Vaswani"},{"given":"Noam","family":"Shazeer"}],
      "issued":{"date-parts":[[2017,6,12]]},
      "container-title":["Advances in Neural Information Processing Systems"]}}
    """

    private let arxivBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:arxiv="http://arxiv.org/schemas/atom"><entry>
      <title>A Very Deep Recurrent Network</title>
      <published>2015-01-02T00:00:00Z</published>
      <author><name>Quoc V. Le</name></author>
      <arxiv:primary_category term="cs.LG"/>
    </entry></feed>
    """

    // MARK: - 1) Recognition succeeds

    func testCrossrefLookupFillsAuthorsYearAndVenue() async throws {
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: 0)
        let metadata = await PaperMetadata.lookup(doi: "10.5555/3295222.3295349", session: session)
        let value = try XCTUnwrap(metadata)
        XCTAssertEqual(value.title, "Attention Is All You Need")
        XCTAssertEqual(value.authors, ["Ashish Vaswani", "Noam Shazeer"])
        XCTAssertEqual(value.year, 2017)
        XCTAssertEqual(value.venue, "Advances in Neural Information Processing Systems")
        XCTAssertEqual(value.doi, "10.5555/3295222.3295349")
    }

    func testArxivLookupFillsMetadataAndCategoryAsVenue() async throws {
        MetadataProtocol.reply = .init(status: 200, body: arxivBody, delay: 0)
        let metadata = await PaperMetadata.lookup(doi: nil, arxivId: "1501.00938", session: session)
        let value = try XCTUnwrap(metadata)
        XCTAssertEqual(value.title, "A Very Deep Recurrent Network")
        XCTAssertEqual(value.authors, ["Quoc V. Le"])
        XCTAssertEqual(value.year, 2015)
        XCTAssertEqual(value.venue, "arXiv cs.LG")
        XCTAssertEqual(value.arxivId, "1501.00938")
    }

    func testIdentifiersAreExtractedFromPublicationText() {
        let blocks = [
            block(0, text: "Attention Is All You Need"),
            block(1, text: "Ashish Vaswani, Noam Shazeer"),
            block(2, text: "doi:10.5555/3295222.3295349"),
            block(3, section: "Abstract", text: "The dominant sequence models..."),
        ]
        let ids = PaperMetadata.extractIdentifiers(from: blocks)
        XCTAssertEqual(ids.doi, "10.5555/3295222.3295349")
    }

    func testDoiFromResolverUrlIsNormalized() {
        let blocks = [block(0, text: "https://doi.org/10.1016/j.cell.2021.04.048")]
        XCTAssertEqual(PaperMetadata.extractIdentifiers(from: blocks).doi, "10.1016/j.cell.2021.04.048")
    }

    func testArxivIdIsExtractedWithoutVersionNoise() {
        let blocks = [block(0, text: "arXiv:2501.01234v2 [cs.LG]")]
        let ids = PaperMetadata.extractIdentifiers(from: blocks)
        XCTAssertEqual(ids.arxivId, "2501.01234v2")
        XCTAssertEqual(PaperLibrary.normalizeArxivId(ids.arxivId), "2501.01234")
    }

    func testPaperWithoutIdentifierYieldsNothing() {
        let blocks = [block(0, text: "A paper with no identifier anywhere.")]
        let ids = PaperMetadata.extractIdentifiers(from: blocks)
        XCTAssertNil(ids.doi)
        XCTAssertNil(ids.arxivId)
    }

    // MARK: - 2) Failure is silent

    func testNetworkFailureReturnsNilInsteadOfThrowing() async {
        MetadataProtocol.reply = .init(status: 503, body: "unavailable", delay: 0)
        let metadata = await PaperMetadata.lookup(doi: "10.5555/3295222.3295349", session: session)
        XCTAssertNil(metadata)
    }

    func testMalformedBodyReturnsNil() async {
        MetadataProtocol.reply = .init(status: 200, body: "not json at all", delay: 0)
        let metadata = await PaperMetadata.lookup(doi: "10.5555/x", session: session)
        XCTAssertNil(metadata)
    }

    func testNoIdentifierSkipsTheNetworkEntirely() async {
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: 0)
        let metadata = await PaperMetadata.lookup(doi: nil, arxivId: "", session: session)
        XCTAssertNil(metadata)
    }

    /// A paper without a DOI must behave exactly as before: no error, no delay.
    func testPaperWithoutDoiKeepsItsExistingBehavior() async throws {
        MetadataProtocol.reply = .init(status: 500, body: "", delay: 0)
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf(), fileName: "no-doi.pdf", projectId: nil)
        let ids = PaperMetadata.extractIdentifiers(from: [block(0, text: "Just some prose.")])
        XCTAssertNil(ids.doi)
        let metadata = await PaperMetadata.lookup(doi: ids.doi, arxivId: ids.arxivId, session: session)
        XCTAssertNil(metadata)
        let fetched = await library.paper(id: paper.id)
        let unchanged = try XCTUnwrap(fetched)
        XCTAssertEqual(unchanged.status, "uploaded")
        XCTAssertEqual(unchanged.metaSource, MetaSource.local)
    }

    // MARK: - 3) Timeout is bounded

    func testSlowResponderDoesNotBlockForever() async throws {
        // Longer than requestTimeout: lookup must still return nil within the budget.
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: PaperMetadata.requestTimeout + 6)
        let started = Date()
        let metadata = await PaperMetadata.lookup(doi: "10.5555/slow", session: session)
        XCTAssertNil(metadata)
        XCTAssertLessThan(Date().timeIntervalSince(started), PaperMetadata.requestTimeout + 5)
    }

    func testRequestCarriesTheHardTimeout() async {
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: 0)
        // The lookup itself must succeed quickly, proving the URLRequest timeout is set.
        let metadata = await PaperMetadata.lookup(doi: "10.5555/fast", session: session)
        XCTAssertNotNil(metadata)
        XCTAssertEqual(PaperMetadata.requestTimeout, 8)
    }

    // MARK: - 4) manual metadata is never overwritten

    func testManualRecordIsNeverOverwritten() async throws {
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: 0)
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf(), fileName: "manual.pdf", projectId: nil)
        try await library.updatePaper { record in
            guard record.id == paper.id else { return }
            record.title = "我的标题"
            record.venue = "我的会议"
            record.metaSource = MetaSource.manual
        }
        let metadata = PaperMetadata.Metadata(
            title: "Attention Is All You Need", authors: ["Ashish Vaswani"],
            year: 2017, venue: "NeurIPS", doi: "10.5555/auto"
        )
        let changed = try await library.applyMetadata(paperId: paper.id, metadata)
        XCTAssertFalse(changed)
        let fetched = await library.paper(id: paper.id)
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.title, "我的标题")
        XCTAssertEqual(record.venue, "我的会议")
        XCTAssertEqual(record.metaSource, MetaSource.manual)
        XCTAssertNil(record.doi)
    }

    func testAutoMetadataFillsEmptyFieldsAndMarksSource() async throws {
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: 0)
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf(), fileName: "auto.pdf", projectId: nil)
        let metadata = PaperMetadata.Metadata(
            title: "Attention Is All You Need", authors: ["Ashish Vaswani"],
            year: 2017, venue: "NeurIPS", doi: "10.5555/auto"
        )
        let applied = try await library.applyMetadata(paperId: paper.id, metadata)
        XCTAssertTrue(applied)
        let fetched = await library.paper(id: paper.id)
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.title, "Attention Is All You Need")
        XCTAssertEqual(record.authors, ["Ashish Vaswani"])
        XCTAssertEqual(record.year, 2017)
        XCTAssertEqual(record.venue, "NeurIPS")
        XCTAssertEqual(record.metaSource, MetaSource.auto)
        // Re-applying identical metadata is a no-op.
        let reapplied = try await library.applyMetadata(paperId: paper.id, metadata)
        XCTAssertFalse(reapplied)
    }

    func testRenamingAPaperMarksMetadataManual() async throws {
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: 0)
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf(), fileName: "rename.pdf", projectId: nil)
        _ = try await library.renamePaper(id: paper.id, title: "我自己起的名字")
        let fetched = await library.paper(id: paper.id)
        let record = try XCTUnwrap(fetched)
        XCTAssertEqual(record.metaSource, MetaSource.manual)
        let metadata = PaperMetadata.Metadata(title: "Auto", authors: ["X"], year: 2020, venue: "V", doi: nil)
        let applied = try await library.applyMetadata(paperId: paper.id, metadata)
        XCTAssertFalse(applied)
        XCTAssertEqual(record.title, "我自己起的名字")
    }

    // MARK: - 5) DOI / arXiv deduplication

    func testDuplicateDoiIsRejectedLikeAShaDuplicate() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: pdf("v1"), fileName: "preprint.pdf", projectId: nil)
        try await library.updatePaper { record in
            guard record.id == first.id else { return }
            record.doi = "10.5555/3295222.3295349"
        }
        // A different file (different SHA) with the same DOI must still be rejected.
        let second = try await library.importPDF(fileData: pdf("v2"), fileName: "published.pdf", projectId: nil)
        do {
            try await library.rejectDuplicateMetadata(doi: "10.5555/3295222.3295349", arxivId: nil)
            XCTFail("Same DOI must be treated as the same paper")
        } catch {
            XCTAssertEqual((error as? PipelineError)?.errorCode, .duplicatePaper)
            XCTAssertTrue("\(error)".contains(second.id) == false, "Error should point at the existing paper, not the new one")
            XCTAssertTrue("\(error)".contains(first.id))
        }
    }

    func testDoiDeduplicationIgnoresResolverPrefixAndCase() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: pdf("v1"), fileName: "a.pdf", projectId: nil)
        try await library.updatePaper { record in
            guard record.id == first.id else { return }
            record.doi = "10.5555/ABC.def"
        }
        do {
            try await library.rejectDuplicateMetadata(doi: "https://doi.org/10.5555/abc.DEF.", arxivId: nil)
            XCTFail("DOI comparison must be normalized")
        } catch {
            XCTAssertEqual((error as? PipelineError)?.errorCode, .duplicatePaper)
        }
    }

    func testDuplicateArxivIdIsRejectedAcrossVersions() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: pdf("v1"), fileName: "a.pdf", projectId: nil)
        try await library.updatePaper { record in
            guard record.id == first.id else { return }
            record.arxivId = "2501.01234"
        }
        do {
            try await library.rejectDuplicateMetadata(doi: nil, arxivId: "arXiv:2501.01234v3")
            XCTFail("arXiv v3 of the same paper is not a new paper")
        } catch {
            XCTAssertEqual((error as? PipelineError)?.errorCode, .duplicatePaper)
        }
    }

    func testUnrelatedDoiIsAccepted() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        _ = try await library.importPDF(fileData: pdf("v1"), fileName: "a.pdf", projectId: nil)
        try await library.updatePaper { record in record.doi = "10.5555/one" }
        var unrelatedRejected = false
        do { try await library.rejectDuplicateMetadata(doi: "10.5555/two", arxivId: nil) }
        catch { unrelatedRejected = true }
        XCTAssertFalse(unrelatedRejected, "A different DOI is a different paper")
        let noIdentifier = await library.existingPaper(doi: nil, arxivId: nil)
        XCTAssertNil(noIdentifier)
    }

    func testDeduplicationIgnoresTheRecordItself() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: pdf("v1"), fileName: "a.pdf", projectId: nil)
        try await library.updatePaper { record in record.doi = "10.5555/self" }
        // Re-running recognition on the same paper must not report a duplicate of itself.
        let itself = await library.existingPaper(doi: "10.5555/self", arxivId: nil, excluding: paper.id)
        XCTAssertNil(itself)
    }
}