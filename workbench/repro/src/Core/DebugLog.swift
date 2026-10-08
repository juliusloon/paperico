import Foundation

// Temporary investigation instrumentation (workbench copy only — never shipped).
func dlog(_ message: String) {
    let ts = Date().timeIntervalSince1970
    FileHandle.standardError.write(Data("[\(String(format: "%.3f", ts))] \(message)\n".utf8))
}
