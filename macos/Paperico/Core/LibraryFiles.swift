import Foundation

/// Called only inside PaperLibrary's actor. No suspension between read, mutate and
/// atomic write: concurrent imports and chat saves cannot overwrite newer data.
enum LibraryFiles {
    static func readJSON<T: Decodable>(_ url: URL, decoder: JSONDecoder) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(T.self, from: Data(contentsOf: url))
        } catch {
            throw PipelineError("无法读取本地数据 \(url.lastPathComponent)：\(error.localizedDescription)。原文件已保留。", .storageFailed)
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder) throws {
        try writeData(encoder.encode(value), to: url)
    }

    static func writeJSONAny(_ value: Any, to url: URL) throws {
        try writeData(JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), to: url)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw PipelineError("无法保存本地数据 \(url.lastPathComponent)：\(error.localizedDescription)", .storageFailed)
        }
    }
}
