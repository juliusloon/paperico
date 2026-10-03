import XCTest
@testable import PapericoCore

final class LLMCompatibilityTests: XCTestCase {
    func testModernTokenRejectionPreservesRequestedOutputLimit() {
        let body = Data(#"{"error":{"message":"Unsupported parameter: max_tokens. Use max_completion_tokens instead."}}"#.utf8)
        let adjusted = LLMClient.compatiblePayload(["max_tokens": 6000, "model": "test", "temperature": 0.3], statusCode: 400, body: body)
        XCTAssertNil(adjusted?["max_tokens"])
        XCTAssertEqual(adjusted?["max_completion_tokens"] as? Int, 6000)
        XCTAssertEqual(adjusted?["model"] as? String, "test")
    }

    func testUnsupportedTemperatureCanBeRemovedAfterTokenRetry() {
        let body = Data(#"{"error":{"message":"temperature does not support this value"}}"#.utf8)
        let adjusted = LLMClient.compatiblePayload(["max_completion_tokens": 6000, "temperature": 0.3], statusCode: 400, body: body)
        XCTAssertNil(adjusted?["temperature"])
        XCTAssertEqual(adjusted?["max_completion_tokens"] as? Int, 6000)
    }

    func testAuthenticationAndUnrelatedErrorsNeverTriggerParameterRetry() {
        let body = Data(#"{"error":{"message":"temperature quota exceeded"}}"#.utf8)
        XCTAssertNil(LLMClient.compatiblePayload(["temperature": 0.3], statusCode: 401, body: body))
        XCTAssertNil(LLMClient.compatiblePayload(["max_tokens": 100], statusCode: 400, body: Data("invalid model".utf8)))
    }

    func testPastedCompletionsEndpointIsNormalized() {
        XCTAssertEqual(LLMClient.normalizeBaseURL(" https://example.test/v1/chat/completions/ "), "https://example.test/v1")
    }
}
