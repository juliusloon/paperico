import XCTest
@testable import PapericoCore

private final class MinerUUploadProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int
        let body: Data
        if request.url?.host == "api.test" {
            let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
                && request.value(forHTTPHeaderField: "Content-Type") == "application/json"
            status = authorized ? 200 : 401
            body = Data(#"{"code":0,"data":{"batch_id":"test-batch","file_urls":["https://storage.test/document.pdf?Signature=test"]}}"#.utf8)
        } else {
            // Reject any extra headers that change the signed upload or leak the token.
            let valid = request.httpMethod == "PUT"
                && request.value(forHTTPHeaderField: "Content-Type") == nil
                && request.value(forHTTPHeaderField: "Authorization") == nil
                && request.httpBodyStream != nil
            status = valid ? 200 : 403
            body = Data()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class MinerUUploadTests: XCTestCase {
    func testSignedUploadOmitsContentTypeAndAPIToken() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MinerUUploadProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let config = MinerUClient.Config(mode: "cloud", baseUrl: "https://api.test", localUrl: "",
                                         token: "test-token", options: MinerUDefaultOptions())
        let result = try await MinerUClient.submitBatch(fileData: Data("%PDF-test".utf8), fileName: "test.pdf",
                                                       config: config, session: session)
        XCTAssertEqual(result.batchId, "test-batch")
        XCTAssertEqual(result.pollType, "batch")
    }
}
