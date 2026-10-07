import XCTest
@testable import PapericoCore

/// T4 的编排规则此前内联在 `PaperPipeline`（app-only 文件），因此最关键的三条
/// 业务规则没有测试背书。现在它们下沉到 `MetadataRecognition`，这里逐一钉住。
final class MetadataRecognitionTests: XCTestCase {

    private func block(_ order: Int, text: String) -> Block {
        Block(id: PaperLibrary.blockId(paperId: "paper-x", order: order), order: order, kind: "paragraph",
              pageIdx: order, bbox: nil, sectionTitle: "", textOriginal: text, textZh: "", oneLiner: "",
              keywords: [], roleInNarrative: "", imagePath: "", captionOriginal: "", captionZh: "",
              figureType: "", coreTakeaways: [], dataReadingNotes: "", tableHtml: "", latex: "",
              plainExplanation: "", entityRefs: [])
    }

    private lazy var doiBlock = [block(0, text: "doi:10.5555/3295222.3295349")]

    /// 记录每一步被调用的顺序，用来断言"先落库、后联网"。
    private actor Trace {
        var calls: [String] = []
        func log(_ name: String) { calls.append(name) }
        func snapshot() -> [String] { calls }
    }

    private struct Harness {
        let trace: Trace
        let actions: MetadataRecognition.Actions
    }

    private func harness(
        metaSource: String = MetaSource.local,
        duplicate: PaperListItem? = nil,
        lookupResult: PaperMetadata.Metadata? = PaperMetadata.Metadata(
            title: "Attention Is All You Need", authors: ["Ashish Vaswani"],
            year: 2017, venue: "NeurIPS", doi: "10.5555/3295222.3295349"),
        writeIdentifiers: ((PaperMetadata.Identifiers) async throws -> Bool)? = nil,
        applyMetadata: ((PaperMetadata.Metadata) async throws -> Void)? = nil
    ) -> Harness {
        let trace = Trace()
        return Harness(trace: trace, actions: .init(
            paperId: "paper-x",
            registerIdentifiers: { ids, _ in
                await trace.log("write")
                if let writeIdentifiers { _ = try await writeIdentifiers(ids) }
                await trace.log("findDuplicate")
                return duplicate
            },
            lookup: { _ in
                await trace.log("lookup")
                return lookupResult
            },
            applyMetadata: { metadata in
                await trace.log("apply")
                if let applyMetadata { try await applyMetadata(metadata) } else { return }
            },
            metaSource: { metaSource }
        ))
    }

    // MARK: - 1) 无标识符不做事

    func testPaperWithoutIdentifierTouchesNothing() async throws {
        let h = harness()
        let outcome = try await MetadataRecognition.run([block(0, text: "Just prose.")], actions: h.actions)
        XCTAssertEqual(outcome, .noIdentifier)
        let calls = await h.trace.snapshot()
        XCTAssertTrue(calls.isEmpty, "识别不得在无标识符时产生任何动作：\(calls)")
    }

    // MARK: - 2) 标识符先于网络落库

    func testIdentifiersAreWrittenBeforeAnyNetworkCall() async throws {
        let h = harness()
        _ = try await MetadataRecognition.run(doiBlock, actions: h.actions)
        let calls = await h.trace.snapshot()
        XCTAssertEqual(calls, ["write", "findDuplicate", "lookup", "apply"],
                       "标识符必须先落库——它来自原文，不依赖网络：\(calls)")
    }

    /// 网络查询失败时，从原文读到的标识符仍要留下痕迹。
    func testIdentifiersSurviveAFailedLookup() async throws {
        let h = harness(lookupResult: nil)
        let outcome = try await MetadataRecognition.run(doiBlock, actions: h.actions)
        XCTAssertEqual(outcome, .recognized)
        let calls = await h.trace.snapshot()
        XCTAssertEqual(calls, ["write", "findDuplicate", "lookup"],
                       "查询失败不应重试写入，也不应报失败：\(calls)")
    }

    func testWriteFailurePropagates() async {
        struct Boom: LocalizedError { var errorDescription: String? { "disk full" } }
        let h = harness(writeIdentifiers: { _ in throw Boom() })
        do {
            _ = try await MetadataRecognition.run(doiBlock, actions: h.actions)
            XCTFail("落盘失败不能被当成识别失败吞掉")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: - 3) manual 记录完全不写

    func testManualRecordIsLeftUntouched() async throws {
        let h = harness(metaSource: MetaSource.manual)
        let outcome = try await MetadataRecognition.run(doiBlock, actions: h.actions)
        XCTAssertEqual(outcome, .noIdentifier)
        let calls = await h.trace.snapshot()
        XCTAssertTrue(calls.isEmpty, "用户手改过的记录不得被写入任何自动字段：\(calls)")
    }

    func testManualRecordIsNotTouchedEvenWhenLookupWouldSucceed() async throws {
        var applied = false
        let h = harness(metaSource: MetaSource.manual, applyMetadata: { _ in applied = true })
        _ = try await MetadataRecognition.run(doiBlock, actions: h.actions)
        XCTAssertFalse(applied)
    }

    // MARK: - 4) 重复论文是唯一允许中断的确定性判断

    func testDuplicateIsReportedWithTheExistingPaper() async throws {
        var existing = PaperListItem.empty(id: "existing-id")
        existing.title = "Attention Is All You Need"
        let h = harness(duplicate: existing)
        let outcome = try await MetadataRecognition.run(doiBlock, actions: h.actions)
        XCTAssertEqual(outcome, .duplicate(existing))
        // 命中重复后不再联网查询：既然是同一篇，没必要再问外部服务。
        let calls = await h.trace.snapshot()
        XCTAssertEqual(calls, ["write", "findDuplicate"])
    }

    func testOnlyDuplicateAndCancellationMayInterruptThePipeline() {
        XCTAssertTrue(MetadataRecognition.shouldInterrupt(PipelineError("重复", .duplicatePaper)))
        XCTAssertTrue(MetadataRecognition.shouldInterrupt(CancellationError()))
        // 识别是锦上添花，其余任何失败都不该让论文变成 error。
        XCTAssertFalse(MetadataRecognition.shouldInterrupt(PipelineError("解析失败", .parseEmpty)))
        XCTAssertFalse(MetadataRecognition.shouldInterrupt(PipelineError("存储失败", .storageFailed)))
        XCTAssertFalse(MetadataRecognition.shouldInterrupt(PipelineError("内部错误", .internalError)))
    }

    func testApplyFailureIsNotSilentlySwallowedHere() async {
        struct Boom: LocalizedError { var errorDescription: String? { "write failed" } }
        let h = harness(applyMetadata: { _ in throw Boom() })
        do {
            _ = try await MetadataRecognition.run(doiBlock, actions: h.actions)
            XCTFail("识别结果落盘失败必须上报，由调用方按错误码决定是否吞掉")
        } catch {
            XCTAssertTrue(error is Boom)
        }
    }

    // MARK: - 5) 与真实库的端到端（探针换成真动作）

    func testRecognitionAgainstARealLibraryFillsMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = PaperLibrary(root: root)
        try await library.load()
        let paper = try await library.importPDF(fileData: Data("%PDF-1.7\nmeta".utf8),
                                                fileName: "meta.pdf", projectId: nil)
        let metadata = PaperMetadata.Metadata(title: "A Paper", authors: ["Ada Lovelace"],
                                             year: 1843, venue: "Notes", doi: "10.5555/3295222.3295349")

        let outcome = try await MetadataRecognition.run(
            [Block(id: "b1", order: 0, kind: "paragraph", pageIdx: 0, bbox: nil, sectionTitle: "",
                   textOriginal: "doi:10.5555/3295222.3295349", textZh: "", oneLiner: "", keywords: [],
                   roleInNarrative: "", imagePath: "", captionOriginal: "", captionZh: "", figureType: "",
                   coreTakeaways: [], dataReadingNotes: "", tableHtml: "", latex: "",
                   plainExplanation: "", entityRefs: [])],
            actions: .init(
                paperId: paper.id,
                registerIdentifiers: { ids, id in
                    try await library.registerIdentifiers(ids, paperId: id)
                },
                lookup: { _ in metadata },
                applyMetadata: { try await library.applyMetadata(paperId: paper.id, $0) },
                metaSource: { await library.paper(id: paper.id)?.metaSource ?? MetaSource.local }
            )
        )
        XCTAssertEqual(outcome, .recognized)
        let stored = await library.paper(id: paper.id)
        XCTAssertEqual(stored?.doi, "10.5555/3295222.3295349")
        XCTAssertEqual(stored?.authors, ["Ada Lovelace"])
        XCTAssertEqual(stored?.year, 1843)
        XCTAssertEqual(stored?.metaSource, MetaSource.auto)
    }
}
