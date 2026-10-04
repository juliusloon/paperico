import Foundation

/// Numeric release tags; metadata does not change version precedence.
struct AppVersion: Comparable, Equatable {
    let parts: [Int]

    init?(_ value: String) {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        guard let core = text.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first else { return nil }
        let tokens = core.split(separator: ".", omittingEmptySubsequences: false)
        guard tokens.count == 3, tokens.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let values = tokens.compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        parts = values
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let htmlUrl: String
    let draft: Bool
    let prerelease: Bool

    static let releasesURL = URL(string: "https://github.com/juliusloon/paperico/releases")!
    static let endpoint = URL(string: "https://api.github.com/repos/juliusloon/paperico/releases/latest")!
    static let latestPage = releasesURL.appendingPathComponent("latest")

    var versionLabel: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    var pageURL: URL? {
        guard let url = URL(string: htmlUrl), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.lowercased().hasPrefix("/juliusloon/paperico/releases/tag/") else { return nil }
        return url
    }

    static func decodeNewer(_ data: Data, currentVersion: String) throws -> AppRelease? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Self.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard let installed = AppVersion(currentVersion), let available = AppVersion(release.tagName), release.pageURL != nil else {
            throw PipelineError("版本信息无法识别，请在发布页检查更新。", .internalError)
        }
        return available > installed ? release : nil
    }

    static func fetch(currentVersion: String, session: URLSession = .shared) async throws -> AppRelease? {
        do { return try await fetchAPI(currentVersion: currentVersion, session: session) }
        catch {
            // Public API requests share an unauthenticated rate limit. GitHub's
            // stable /latest redirect permits checks without a token or scraping.
            var request = URLRequest(url: latestPage, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "HEAD"
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, let url = response.url else { throw error }
            return try fromLatestPage(url, currentVersion: currentVersion)
        }
    }

    static func fromLatestPage(_ url: URL, currentVersion: String) throws -> AppRelease? {
        let release = AppRelease(tagName: url.lastPathComponent, htmlUrl: url.absoluteString, draft: false, prerelease: false)
        guard release.pageURL != nil, let available = AppVersion(release.tagName), let installed = AppVersion(currentVersion) else {
            throw PipelineError("版本信息无法识别，请在发布页检查更新。", .internalError)
        }
        return available > installed ? release : nil
    }

    private static func fetchAPI(currentVersion: String, session: URLSession) async throws -> AppRelease? {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Paperico/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else {
            let message = [403, 429].contains(response.statusCode)
                ? "检查更新暂时受限，请稍后重试。" : "无法读取发布版本（HTTP \(response.statusCode)），请稍后重试。"
            throw PipelineError(message, .internalError)
        }
        return try decodeNewer(data, currentVersion: currentVersion)
    }
}
