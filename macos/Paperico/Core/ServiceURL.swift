import Foundation

enum ServiceURL {
    static func endpoint(base: String, path: String) throws -> URL {
        var normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        guard let url = URL(string: normalized + path),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else {
            throw PipelineError("服务地址无效，请填写包含 http:// 或 https:// 的完整地址。")
        }
        return url
    }
}
