import XCTest
@testable import PapericoCore

final class ServiceURLTests: XCTestCase {
    func testNormalizesTrailingSlashAndWhitespace() throws {
        XCTAssertEqual(try ServiceURL.endpoint(base: " https://example.test/v1/\n", path: "/models").absoluteString,
                       "https://example.test/v1/models")
        XCTAssertEqual(try ServiceURL.endpoint(base: "http://127.0.0.1:7860", path: "/gradio_api/info").port, 7860)
    }

    func testInvalidConfigurationThrowsInsteadOfCrashing() {
        for base in ["", "example.test/v1", "https://", "file:///tmp/model", "http://["] {
            XCTAssertThrowsError(try ServiceURL.endpoint(base: base, path: "/chat/completions"), base)
        }
    }
}
