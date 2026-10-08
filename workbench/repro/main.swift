import Foundation

// Replicates LLMClient.agentResponse's streaming branch exactly (URLSession.shared,
// bytes(for:), .lines), with full instrumentation of the raw byte stream.

struct IterationResult {
    var index: Int
    var start: Date
    var headersAt: TimeInterval?
    var status: Int?
    var contentType: String?
    var transferEncoding: String?
    var connection: String?
    var bodyBytes = Data()
    var firstChunkAt: TimeInterval?
    var lastByteAt: TimeInterval?
    var lineCount = 0
    var sseEventCount = 0
    var outcome = ""       // completed / error / cancelled
    var errorDescription = ""
    var finishedAt: TimeInterval?
}

@main
struct Repro {
    static func main() async {
        let args = CommandLine.arguments
        let payloadURL = URL(fileURLWithPath: args[1])
        let apiKey = args[2]
        let iterations = args.count > 3 ? Int(args[3])! : 10
        let baseURL = "https://strata.local:8443/v1"

        let payloadData = try! Data(contentsOf: payloadURL)

        let session = URLSession.shared
        var results: [IterationResult] = []

        for i in 0..<iterations {
            var r = IterationResult(index: i, start: Date())
            let task = Task {
                do {
                    guard let url = URL(string: baseURL + "/chat/completions") else { throw NSError(domain: "repro", code: 1) }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.httpBody = payloadData
                    let (bytes, response) = try await session.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    r.headersAt = Date().timeIntervalSince(r.start)
                    r.status = http?.statusCode
                    r.contentType = http?.value(forHTTPHeaderField: "Content-Type")
                    r.transferEncoding = http?.value(forHTTPHeaderField: "Transfer-Encoding")
                    r.connection = http?.value(forHTTPHeaderField: "Connection")
                    guard let http, (200..<300).contains(http.statusCode) else {
                        r.outcome = "error"; r.errorDescription = "bad status"
                        for try await _ in bytes { }
                        r.finishedAt = Date().timeIntervalSince(r.start)
                        return
                    }
                    // Exact App loop: iterate lines, keep raw bytes too.
                    for try await line in bytes.lines {
                        if r.firstChunkAt == nil { r.firstChunkAt = Date().timeIntervalSince(r.start) }
                        r.lineCount += 1
                        r.bodyBytes.append(contentsOf: line.utf8)
                        r.bodyBytes.append(0x0a)
                        r.lastByteAt = Date().timeIntervalSince(r.start)
                        if r.bodyBytes.count > 4_000_000 { break }
                        let text = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if line.hasPrefix("data:"), text != "[DONE]" { r.sseEventCount += 1 }
                        try Task.checkCancellation()
                    }
                    r.outcome = "completed"
                    r.finishedAt = Date().timeIntervalSince(r.start)
                } catch is CancellationError {
                    r.outcome = "cancelled(CancellationError)"
                    r.finishedAt = Date().timeIntervalSince(r.start)
                } catch {
                    r.outcome = "error"
                    r.errorDescription = String(describing: error)
                    r.finishedAt = Date().timeIntervalSince(r.start)
                }
            }
            // Iteration watchdog: 100s
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 100_000_000_000)
                if !task.isCancelled { task.cancel() }
            }
            _ = await task.result
            watchdog.cancel()
            results.append(r)
            print("iter \(i): outcome=\(r.outcome) status=\(r.status ?? -1) headersAt=\(String(format: "%.3f", r.headersAt ?? -1))s firstByte=\(r.firstChunkAt.map{String(format: "%.3f", $0)} ?? "-") bodyBytes=\(r.bodyBytes.count) lines=\(r.lineCount) sse=\(r.sseEventCount) ct=\(r.contentType ?? "-") te=\(r.transferEncoding ?? "-") err=\(r.errorDescription)")
            if r.bodyBytes.count < 2000, !r.bodyBytes.isEmpty {
                print("  RAW BODY (\(r.bodyBytes.count)B): \(String(decoding: r.bodyBytes, as: UTF8.self).prefix(1500))")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        print("\n===== SUMMARY =====")
        for r in results {
            print("\(r.index)\t\(r.outcome)\tstatus=\(r.status ?? -1)\tfirstByte=\(r.firstChunkAt.map{String(format: "%.3f", $0)} ?? "-")s\tbody=\(r.bodyBytes.count)B\tsse=\(r.sseEventCount)\t\(r.errorDescription)")
        }
    }
}
