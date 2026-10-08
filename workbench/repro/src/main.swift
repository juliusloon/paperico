import Foundation

// Repro driver: runs the real ChatService.send (agent path) against the real
// library and the real LLM, in a loop, with the failing broad question.

@main
struct ReproDriver {
    static func main() async {
        let args = CommandLine.arguments
        let apiKey = args[1]
        let iterations = args.count > 2 ? Int(args[2])! : 5
        let paperId = args.count > 3 ? args[3] : "e79d19f0260d"
        let question = args.count > 4 ? args[4] : "请把论文库里全部11篇论文每一篇的贡献、方法、局限都详细梳理一遍，每篇都要逐一引用库内证据块，不要遗漏任何一篇。"
        let supportsTools = args.count > 5 ? (args[5] == "tools") : true

        let libraryRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/com.paperico.native/Data/Library/Application Support/Paperico")
        let library = PaperLibrary(root: libraryRoot)
        do { try await library.load() } catch {
            print("library load failed: \(error)"); return
        }
        guard await library.paper(id: paperId) != nil else {
            print("paper \(paperId) not found"); return
        }

        let llm = AnalysisEngine.LLMConfig(
            baseURL: "https://strata.local:8443/v1",
            apiKey: apiKey,
            model: "qwen3.8-flash-next-iq3_s",
            reasoningEffort: "high",
            temperature: 0.3,
            maxTokens: 65536,
            streaming: true,
            supportsTools: supportsTools
        )

        struct Iter { var ok: Bool; var contentLen: Int; var rounds: Int; var calls: Int; var retrieved: Int; var error: String }
        var results: [Iter] = []

        for i in 0..<iterations {
            dlog("===== ITER \(i) start =====")
            var content = ""; var sessionId = ""; var rounds = 0; var calls = 0; var failed = false; var errDesc = ""
            var retrievedPapers = 0; var retrievalMs = 0.0
            do {
                let stream = ChatService.send(
                    paperId: paperId, content: question, sessionId: nil, attachedContext: nil,
                    library: library, llm: llm, allowLibraryContext: true
                )
                for try await event in stream {
                    if let c = event.content { content += c }
                    if let sid = event.sessionId { sessionId = sid }
                    rounds = max(rounds, event.libraryToolRounds ?? 0)
                    calls = max(calls, event.libraryQueryCount ?? 0)
                    if let n = event.libraryPaperCount { retrievedPapers = max(retrievedPapers, n) }
                    if let ms = event.retrievalMilliseconds { retrievalMs = ms }
                }
            } catch {
                failed = true
                errDesc = String(describing: error)
            }
            let state = (try? await library.chatSession(paperId: paperId, sessionId: sessionId))??.messages.last?.generationState ?? "?"
            let msText = String(format: "%.0f", retrievalMs)
            dlog("===== ITER \(i) end ok=\(!failed) contentLen=\(content.count) rounds=\(rounds) calls=\(calls) retrievedPapers=\(retrievedPapers) retrievalMs=\(msText) lastMsgState=\(state) err=\(errDesc) =====")
            results.append(Iter(ok: !failed, contentLen: content.count, rounds: rounds, calls: calls, retrieved: retrievedPapers, error: errDesc))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        print("\n===== DRIVER SUMMARY =====")
        for (i, r) in results.enumerated() {
            print("\(i)\tok=\(r.ok)\tcontent=\(r.contentLen)\trounds=\(r.rounds)\tcalls=\(r.calls)\tretrieved=\(r.retrieved)\t\(r.error)")
        }
    }
}
