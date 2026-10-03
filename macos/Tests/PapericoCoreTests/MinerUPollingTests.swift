import XCTest
@testable import PapericoCore

private final class MinerUPollProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var submissions = 0
    private static var queuePolls = 0
    private let stateLock = NSLock()
    private var stopped = false

    static func reset() { lock.lock(); defer { lock.unlock() }; submissions = 0; queuePolls = 0 }
    static func submissionCount() -> Int { lock.lock(); defer { lock.unlock() }; return submissions }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.host == "slow.test" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.respond(#"{"code":0,"data":{"extract_result":[{"state":"running"}]}}"#)
            }
        } else if request.url?.path == "/file-urls/batch" {
            Self.lock.lock(); Self.submissions += 1; Self.lock.unlock()
            respond(#"{"code":0,"data":{"batch_id":"saved-batch","file_urls":["https://upload.test/paper.pdf"]}}"#)
        } else if request.url?.host == "upload.test" {
            respond("{}")
        } else if request.url?.host == "invalid.test" {
            respond(#"{"code":0,"data":{"unexpected":"response"}}"#)
        } else if request.url?.host == "failed.test" {
            respond(#"{"code":0,"data":{"extract_result":[{"state":"failed","err_msg":"quota exhausted"}]}}"#)
        } else if request.url?.host == "queued.test" {
            Self.lock.lock(); Self.queuePolls += 1; let count = Self.queuePolls; Self.lock.unlock()
            if count == 1 {
                respond(#"{"code":0,"trace_id":"queue-trace","data":{"extract_result":[{"state":"pending"}]}}"#)
            } else {
                respond(#"{"code":0,"trace_id":"failure-trace","data":{"extract_result":[{"state":"failed","err_msg":"actual provider failure"}]}}"#)
            }
        } else {
            respond(#"{"code":0,"data":{"extract_result":[{"state":"running","extract_progress":{"extracted_pages":2,"total_pages":12}}]}}"#)
        }
    }

    private func respond(_ body: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

private actor MinerUProgressMessages {
    var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}

final class MinerUPollingTests: XCTestCase {
    private var root: URL!
    private var session: URLSession!
    private let submitted = MinerUClient.SubmitResult(taskId: "", batchId: "saved-batch", pollType: "batch")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MinerUPollProtocol.self]
        session = URLSession(configuration: configuration)
        MinerUPollProtocol.reset()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    private func config(_ host: String) -> MinerUClient.Config {
        MinerUClient.Config(mode: "cloud", baseUrl: "https://\(host)", localUrl: "", token: "test", options: MinerUDefaultOptions())
    }

    func testDeadlineIncludesSlowNetworkRequest() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await MinerUClient.waitForResult(submit: submitted, config: config("slow.test"), session: session,
                                                     pollInterval: 0.01, maxWait: 0.03)
            XCTFail("A slow request must not extend the deadline")
        } catch { XCTAssertEqual((error as? MinerUServiceError)?.errorCode, .mineruTimeout) }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testInvalidResponseFailsInsteadOfSilentlyWaiting() async throws {
        do {
            _ = try await MinerUClient.waitForResult(submit: submitted, config: config("invalid.test"), session: session, maxWait: 1)
            XCTFail("Malformed responses must not be treated as pending tasks")
        } catch { XCTAssertEqual((error as? MinerUServiceError)?.errorCode, .mineruParseFailed) }
    }

    func testTimeoutRetryResumesBatchAndReportsPageProgress() async throws {
        let messages = MinerUProgressMessages()
        for _ in 0..<2 {
            do {
                _ = try await MinerUClient.runFullPipeline(fileData: Data("%PDF-test".utf8), fileName: "test.pdf", pdfURL: nil,
                                                          config: config("running.test"), outputDir: root,
                                                          pollInterval: 0.01, maxWait: 0.03, session: session,
                                                          progress: { await messages.append($0) })
                XCTFail("Running task should time out")
            } catch { XCTAssertEqual((error as? MinerUServiceError)?.errorCode, .mineruTimeout) }
        }
        XCTAssertEqual(MinerUPollProtocol.submissionCount(), 1)
        let progress = await messages.messages
        XCTAssertTrue(progress.contains("正在继续已有的 MinerU 云端任务"))
        XCTAssertTrue(progress.contains("MinerU 正在解析：2 / 12 页"))
    }

    func testForcedReparseSubmitsNewTaskAndTerminalFailureClearsCheckpoint() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("old_content_list.json"))
        for force in [false, true] {
            do {
                _ = try await MinerUClient.runFullPipeline(fileData: Data("%PDF-test".utf8), fileName: "test.pdf", pdfURL: nil,
                                                          config: config("running.test"), outputDir: root,
                                                          pollInterval: 0.01, maxWait: 0.02, forceNewTask: force, session: session)
            } catch { XCTAssertEqual((error as? MinerUServiceError)?.errorCode, .mineruTimeout) }
        }
        XCTAssertEqual(MinerUPollProtocol.submissionCount(), 2)
        XCTAssertNil(MinerUClient.findContentList(in: root), "An unfinished reparse must supersede old content")
        do {
            _ = try await MinerUClient.runFullPipeline(fileData: Data("%PDF-test".utf8), fileName: "test.pdf", pdfURL: nil,
                                                      config: config("failed.test"), outputDir: root, session: session)
            XCTFail("Terminal failures must be surfaced")
        } catch {
            XCTAssertEqual((error as? MinerUServiceError)?.errorCode, .mineruParseFailed)
            XCTAssertTrue(error.localizedDescription.contains("quota exhausted"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cloud-task.json").path))
    }

    func testLatestDownloadIsPreferredOverOldShallowResult() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("result-new"), withIntermediateDirectories: true)
        let old = root.appendingPathComponent("old_content_list.json")
        let latest = root.appendingPathComponent("result-new/new_content_list.json")
        try Data("[]".utf8).write(to: old)
        try Data("[]".utf8).write(to: latest)
        try Data("result-new/new_content_list.json".utf8).write(to: root.appendingPathComponent("latest-content-list.txt"))
        XCTAssertEqual(MinerUClient.findContentList(in: root)?.standardizedFileURL, latest.standardizedFileURL)
    }

    func testQueueObservationTimeoutContinuesSameJobUntilActualProviderFailure() async throws {
        let messages = MinerUProgressMessages()
        let states = MinerUProgressMessages()
        do {
            _ = try await MinerUClient.runFullPipeline(fileData: Data("%PDF-test".utf8), fileName: "test.pdf", pdfURL: nil,
                                                      config: config("queued.test"), outputDir: root, pollInterval: 0.01,
                                                      maxWait: 0.02, session: session, waitForQueuedTask: true,
                                                      queuedRetryInterval: 0.001, stateChanged: { await states.append($0) },
                                                      progress: { await messages.append($0) })
            XCTFail("An actual provider failure must still surface")
        } catch {
            XCTAssertEqual((error as? MinerUServiceError)?.errorCode, .mineruParseFailed)
            XCTAssertTrue(error.localizedDescription.contains("actual provider failure"))
        }
        XCTAssertEqual(MinerUPollProtocol.submissionCount(), 1, "Queue observation must never resubmit the PDF")
        let progress = await messages.messages
        XCTAssertTrue(progress.contains("MinerU 云端仍在排队，尚未开始解析；将自动继续等待"))
        let cloudStates = await states.messages
        XCTAssertEqual(cloudStates, ["pending", "failed"])
        let data = try Data(contentsOf: root.appendingPathComponent("cloud-status.json"))
        let log = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(log["state"] as? String, "failed")
        XCTAssertEqual(log["trace_id"] as? String, "failure-trace")
        XCTAssertNil(log["token"])
    }
}
