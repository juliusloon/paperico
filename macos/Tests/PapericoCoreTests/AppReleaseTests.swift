import XCTest
@testable import PapericoCore

final class AppReleaseTests: XCTestCase {
    func testVersionsUseNumericOrderAndIgnoreMetadata() {
        XCTAssertTrue(AppVersion("0.10.0")! > AppVersion("v0.9.9")!)
        XCTAssertEqual(AppVersion("v1.2.3+build.9"), AppVersion("1.2.3"))
        for tag in ["", "v", "1.2", "1..3", "1.2.3-rc1", "1.2.3.4", "latest", "-1.2.3"] {
            XCTAssertNil(AppVersion(tag), tag)
        }
    }

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, url: String = "https://github.com/juliusloon/paperico/releases/tag/v0.4.0") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": url, "draft": draft, "prerelease": prerelease])
    }

    func testOnlyNewerOfficialReleasesTriggerAnUpdate() throws {
        XCTAssertNotNil(try AppRelease.decodeNewer(release("v0.4.0"), currentVersion: "0.3.0"))
        XCTAssertNil(try AppRelease.decodeNewer(release("v0.3.0"), currentVersion: "0.3.0"))
        XCTAssertNil(try AppRelease.decodeNewer(release("v0.2.5"), currentVersion: "0.3.0"))
        XCTAssertNil(try AppRelease.decodeNewer(release("v0.4.0", draft: true), currentVersion: "0.3.0"))
        XCTAssertNil(try AppRelease.decodeNewer(release("v0.4.0-rc1", prerelease: true), currentVersion: "0.3.0"))
    }

    func testInvalidReleaseDataCannotOpenAnUnrelatedURL() throws {
        for url in ["https://example.com/download", "http://github.com/juliusloon/paperico/releases/tag/v0.4.0", "https://github.com/other/app/releases/tag/v0.4.0"] {
            XCTAssertThrowsError(try AppRelease.decodeNewer(release("v0.4.0", url: url), currentVersion: "0.3.0"))
        }
        XCTAssertThrowsError(try AppRelease.decodeNewer(Data("{}".utf8), currentVersion: "0.3.0"))
    }

    func testLatestPageRedirectUsesOnlyValidatedReleaseTags() throws {
        XCTAssertNotNil(try AppRelease.fromLatestPage(URL(string: "https://github.com/juliusloon/Paperico/releases/tag/v0.4.0")!, currentVersion: "0.3.0"))
        XCTAssertNil(try AppRelease.fromLatestPage(URL(string: "https://github.com/juliusloon/paperico/releases/tag/v0.3.0")!, currentVersion: "0.3.0"))
        for url in ["https://example.com/releases/tag/v0.4.0", "https://github.com/juliusloon/paperico/releases/latest", "https://github.com/juliusloon/paperico/releases/tag/v0.4.0-rc1"] {
            XCTAssertThrowsError(try AppRelease.fromLatestPage(URL(string: url)!, currentVersion: "0.3.0"))
        }
    }

    func testRateLimitedAPIFallsBackToOfficialLatestPage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitedReleaseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let release = try await AppRelease.fetch(currentVersion: "0.3.0", session: session)
        XCTAssertEqual(release?.versionLabel, "0.4.0")
    }
}

private final class RateLimitedReleaseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response: HTTPURLResponse
        if request.url == AppRelease.endpoint {
            response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        } else if request.url == AppRelease.latestPage, request.httpMethod == "HEAD" {
            response = HTTPURLResponse(url: URL(string: "https://github.com/juliusloon/paperico/releases/tag/v0.4.0")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
