import XCTest
@testable import PapericoCore

/// Mocks Crossref / arXiv Atom and the "network is down" case.
private final class MetadataProtocol: URLProtocol {
    struct Reply { let status: Int; let body: String; let delay: TimeInterval }
    nonisolated(unsafe) static var reply = Reply(status: 200, body: "{}", delay: 0)
    nonisolated(unsafe) static var lastRequest: URLRequest?
    private var pending: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let reply = Self.reply
        let client = self.client
        let stub = self
        let url = request.url!
        let work = DispatchWorkItem {
            let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(stub, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(stub)
        }
        pending = work
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work)
        } else {
            work.perform()
        }
    }
    override func stopLoading() { pending?.cancel() }
}

private final class StreamingMetadataProtocol: URLProtocol {
    private var timer: DispatchSourceTimer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let timer = DispatchSource.makeTimerSource(queue: .global())
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data(" ".utf8))
        }
        timer.resume()
    }
    override func stopLoading() { timer?.cancel() }
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

    func testDoiPreservesBalancedParenthesesAndDropsSurroundingPunctuation() {
        let doi = "10.1016/S0140-6736(20)30183-5"
        for source in ["doi:\(doi)", "(https://doi.org/\(doi))", "[\(doi)]"] {
            XCTAssertEqual(PaperMetadata.extractIdentifiers(from: [block(0, text: source)]).doi, doi)
        }
    }

    func testParserRetainsIdentifiersFromFirstPageHeadersAndFooters() throws {
        let content = root.appendingPathComponent("content_list.json")
        let items: [[String: Any]] = [
            ["type": "header", "page_idx": 0, "text": "https://doi.org/10.1038/s41467-026-75713-2"],
            ["type": "footer", "page_idx": 0, "text": "arXiv:2501.01234v2"],
            ["type": "header", "page_idx": 1, "text": "10.5555/repeated"],
            ["type": "page_number", "page_idx": 0, "text": "1"],
        ]
        try JSONSerialization.data(withJSONObject: items).write(to: content)
        let raw = try MinerUClient.parseContentList(at: content, dataRoot: root)
        XCTAssertEqual(raw.count, 2)
        let ids = PaperMetadata.extractIdentifiers(publicationTexts: raw.compactMap { $0["text_original"] as? String })
        XCTAssertEqual(ids.doi, "10.1038/s41467-026-75713-2")
        XCTAssertEqual(ids.arxivId, "2501.01234v2")
    }

    func testArxivUsesHTTPSInsideTheAppTransportPolicy() async {
        MetadataProtocol.reply = .init(status: 200, body: arxivBody, delay: 0)
        _ = await PaperMetadata.lookup(arxivId: "1501.00938", session: session)
        XCTAssertEqual(MetadataProtocol.lastRequest?.url?.scheme, "https")
    }

    func testErrorStatusDoesNotApplyAnOtherwiseValidResponse() async {
        MetadataProtocol.reply = .init(status: 503, body: crossrefBody, delay: 0)
        let result = await PaperMetadata.lookup(doi: "10.5555/x", session: session)
        XCTAssertNil(result)
    }

    func testDoiReservedURLCharactersStayInsideThePath() async {
        MetadataProtocol.reply = .init(status: 200, body: crossrefBody, delay: 0)
        _ = await PaperMetadata.lookup(doi: "10.5555/a?b#c", session: session)
        XCTAssertNil(MetadataProtocol.lastRequest?.url?.query)
        XCTAssertNil(MetadataProtocol.lastRequest?.url?.fragment)
        XCTAssertEqual(MetadataProtocol.lastRequest?.url?.path, "/works/10.5555/a?b#c")
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

    func testContinuouslyStreamingResponseStillHitsTheTotalDeadline() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingMetadataProtocol.self]
        let streamingSession = URLSession(configuration: config)
        defer { streamingSession.invalidateAndCancel() }
        let start = ContinuousClock.now
        let result = await PaperMetadata.lookup(doi: "10.5555/drip", session: streamingSession)
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(PaperMetadata.requestTimeout + 2))
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
    //
    // 生产路径：PaperPipeline 把 existingPaper(doi:arxivId:excluding:) 注入
    // MetadataRecognition.findDuplicate，在解析后、模型分析前完成去重。
    // 这里直接针对该入口断言匹配语义。

    func testDuplicateDoiResolvesToTheExistingPaper() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: pdf("v1"), fileName: "preprint.pdf", projectId: nil)
        try await library.updatePaper { record in
            guard record.id == first.id else { return }
            record.doi = "10.5555/3295222.3295349"
        }
        // A different file (different SHA) with the same DOI must resolve to the first paper.
        let second = try await library.importPDF(fileData: pdf("v2"), fileName: "published.pdf", projectId: nil)
        let duplicate = await library.existingPaper(doi: "10.5555/3295222.3295349", arxivId: nil, excluding: second.id)
        XCTAssertEqual(duplicate?.id, first.id, "Same DOI must be treated as the same paper")
    }

    func testDoiDeduplicationIgnoresResolverPrefixAndCase() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: pdf("v1"), fileName: "a.pdf", projectId: nil)
        try await library.updatePaper { record in
            guard record.id == first.id else { return }
            record.doi = "10.5555/ABC.def"
        }
        let duplicate = await library.existingPaper(doi: "https://doi.org/10.5555/abc.DEF.", arxivId: nil)
        XCTAssertEqual(duplicate?.id, first.id, "DOI comparison must be normalized")
    }

    func testDuplicateArxivIdMatchesAcrossVersions() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: pdf("v1"), fileName: "a.pdf", projectId: nil)
        try await library.updatePaper { record in
            guard record.id == first.id else { return }
            record.arxivId = "2501.01234"
        }
        let duplicate = await library.existingPaper(doi: nil, arxivId: "arXiv:2501.01234v3")
        XCTAssertEqual(duplicate?.id, first.id, "arXiv v3 of the same paper is not a new paper")
    }

    func testUnrelatedDoiIsAccepted() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        _ = try await library.importPDF(fileData: pdf("v1"), fileName: "a.pdf", projectId: nil)
        try await library.updatePaper { record in record.doi = "10.5555/one" }
        let unrelated = await library.existingPaper(doi: "10.5555/two", arxivId: nil)
        XCTAssertNil(unrelated, "A different DOI is a different paper")
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

    func testConcurrentIdentifierRegistrationKeepsOneOwnerAndAllowsItsRetry() async throws {
        let library = PaperLibrary(root: root)
        try await library.load()
        let first = try await library.importPDF(fileData: pdf("a"), fileName: "a.pdf", projectId: nil)
        let second = try await library.importPDF(fileData: pdf("b"), fileName: "b.pdf", projectId: nil)
        let ids = PaperMetadata.Identifiers(doi: "10.5555/shared")
        async let a = library.registerIdentifiers(ids, paperId: first.id)
        async let b = library.registerIdentifiers(ids, paperId: second.id)
        let results = try await [a, b]
        XCTAssertEqual(results.compactMap { $0 }.count, 1, "Exactly one duplicate must be rejected")
        let owner = try XCTUnwrap(results.compactMap { $0 }.first)
        let rejectedId = owner.id == first.id ? second.id : first.id
        try await library.setStatus(paperId: rejectedId, status: "parsing")
        try await library.setStatus(paperId: rejectedId, status: "normalizing")
        let retry = try await library.registerIdentifiers(ids, paperId: owner.id)
        XCTAssertNil(retry, "The rejected duplicate must not reject its owner on retry")
        let reloaded = PaperLibrary(root: root)
        try await reloaded.load()
        let retryAfterRestart = try await reloaded.registerIdentifiers(ids, paperId: owner.id)
        XCTAssertNil(retryAfterRestart)
        try await reloaded.deletePaper(id: owner.id)
        try await reloaded.setStatus(paperId: rejectedId, status: "normalizing")
        let acceptedAfterOwnerRemoval = try await reloaded.registerIdentifiers(ids, paperId: rejectedId)
        XCTAssertNil(acceptedAfterOwnerRemoval)
        let accepted = await reloaded.paper(id: rejectedId)
        XCTAssertNil(accepted?.errorCode)
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("library.json"))) as? [String: Any]
        XCTAssertTrue((index?["metadata_duplicate_by_paper_id"] as? [String: String] ?? [:]).isEmpty)
    }
}
