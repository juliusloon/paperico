import Foundation
import Observation

/// 原生论文管线：MinerU 解析 → 规范化 → 一次流式全文分析 → 本地持久化。
@MainActor
@Observable
final class PaperPipeline {

    private let library: PaperLibrary
    private let settings: SettingsStore

    /// 每篇论文在跑的任务;取消即 Task.cancel(),各阶段检查点自行退出。
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private(set) var failures: [String: String] = [:]
    private(set) var progress: [String: String] = [:]
    private(set) var cloudStates: [String: String] = [:]
    struct NodeProgress: Equatable { let completed: Int; let total: Int }
    private(set) var nodeProgress: [String: NodeProgress] = [:]

    /// 上传/本地解析和模型调用的并发闸门；云端排队不占用上传许可。
    ///
    /// 本地 MinerU 是同一台机器上的同一个服务实例,并发提交两份只会互相拖慢,
    /// 因此本地解析串行化(limit 1);云端是远端服务,保持 2 并发。
    private let localParseGate = JobGate(limit: JobGateLimit.localParse)
    private let cloudGate = JobGate(limit: JobGateLimit.cloudParse)
    private let llmGate = JobGate(limit: JobGateLimit.llm)

    init(library: PaperLibrary, settings: SettingsStore) {
        self.library = library
        self.settings = settings
    }

    var isConfigured: Bool {
        let mineru = settings.mineruClientConfig()
        return settings.llmConfig(for: .translation).isConfigured
            && (mineru.mode == "local" || !mineru.token.isEmpty)
    }

    // MARK: - 入口

    /// 导入后启动完整管线:解析 → 单次全文分析。
    func startProcessing(paperId: String) {
        spawn(paperId: paperId, mode: .full)
    }

    func runMetadataRecognition(paperId: String) async throws -> MetadataRecognition.Outcome {
        guard tasks[paperId] == nil else { throw PipelineError("论文正在处理中，请完成后再识别元数据。", .parseEmpty) }
        return try await MetadataRecognition.backfill(paperId: paperId, library: library)
    }

    /// 重新解析:明确提交新的 MinerU 任务，不复用旧任务或解析文件。
    func reparse(paperId: String) {
        spawn(paperId: paperId, mode: .reparse)
    }

    /// 重新翻译:复用已解析的 blocks,只重跑一次全文分析。
    func retranslate(paperId: String) {
        spawn(paperId: paperId, mode: .retranslate)
    }

    /// Recover saved model output locally without uploading or generating again.
    func recoverAnalysis(paperId: String) { spawn(paperId: paperId, mode: .recover) }

    func cancel(paperId: String) async {
        let task = tasks[paperId]
        let generation = generations[paperId]
        task?.cancel()
        await task?.value
        if generations[paperId] == generation {
            tasks[paperId] = nil
            generations[paperId] = nil
        }
    }

    /// 读取当前状态(轮询接口,等价 papersStatus;数据在内存索引里,零 IO)。
    func status(paperId: String) async -> PaperStatusOut? {
        guard let record = await library.paper(id: paperId) else { return nil }
        return PaperStatusOut(
            id: record.id, status: record.status,
            errorMessage: record.errorMessage, errorCode: record.errorCode
        )
    }

    var isProcessing: (String) -> Bool {
        { self.tasks[$0] != nil }
    }

    func statusLabel(for paper: PaperListItem) -> String {
        if paper.status == "parsing", cloudStates[paper.id] == "pending" { return "云端排队中" }
        return paper.statusEnum.label == "未知" ? paper.status : paper.statusEnum.label
    }

    private enum Mode { case full, reparse, retranslate, recover }

    private func spawn(paperId: String, mode: Mode) {
        let previous = tasks[paperId]
        previous?.cancel()
        let generation = UUID()
        generations[paperId] = generation
        failures[paperId] = nil
        progress[paperId] = "正在准备"
        cloudStates[paperId] = nil
        nodeProgress[paperId] = nil
        tasks[paperId] = Task { [weak self] in
            guard let self else { return }
            // Wait for old writes/network work to finish before retrying the same paper.
            await previous?.value
            defer {
                if self.generations[paperId] == generation {
                    self.tasks[paperId] = nil
                    self.generations[paperId] = nil
                    self.progress[paperId] = nil
                    self.cloudStates[paperId] = nil
                    self.nodeProgress[paperId] = nil
                }
            }
            guard !Task.isCancelled else { return }
            switch mode {
            case .full: await self.runFullPipeline(paperId: paperId)
            case .reparse: await self.runFullPipeline(paperId: paperId, forceReparse: true)
            case .retranslate: await self.runRetranslate(paperId: paperId)
            case .recover: await self.runRecovery(paperId: paperId)
            }
        }
    }

    private func recordFailure(_ error: Error, paperId: String) async {
        let cancelled = Task.isCancelled || error is CancellationError
        let message = cancelled ? "处理已停止，可重新解析或重新翻译。" : ApiFailure.wrap(error).localizedDescription
        let code = cancelled ? ErrorCode.cancelled.rawValue
            : (error as? PipelineError)?.errorCode.rawValue
                ?? (error as? MinerUServiceError)?.errorCode.rawValue
                ?? ErrorCode.llmCallFailed.rawValue
        do {
            try await library.setStatus(paperId: paperId, status: "error", errorMessage: String(message.prefix(500)), errorCode: code)
        } catch {
            failures[paperId] = ApiFailure.wrap(error).localizedDescription
        }
    }

    // MARK: - 完整管线

    private func runFullPipeline(paperId: String, forceReparse: Bool = false) async {
        guard let paper = await library.paper(id: paperId) else { return }
        do {
            try await waitForCredentials(paperId: paperId)
            let mineruConfig = settings.mineruClientConfig()
            let llmConfig = settings.llmConfig(for: .translation)
            if mineruConfig.mode != "local" && mineruConfig.token.isEmpty {
                throw PipelineError("未配置可用的 MinerU Token，请先在设置页保存并测试连接", .mineruNotConfigured)
            }
            guard llmConfig.isConfigured else {
                throw PipelineError("未配置可用的模型 API，请先在设置页保存并测试连接", .llmNotConfigured)
            }

            // Step 1: 解析;若此前只缺 AI 分析,复用已完成的解析输出。
            let outputDir = await library.mineruOutputDir(paperId)
            var contentListURL: URL?
            if !forceReparse, let cached = MinerUClient.findContentList(in: outputDir) {
                progress[paperId] = "正在复用已完成的 MinerU 解析结果"
                contentListURL = cached
            } else {
                try await library.setStatus(paperId: paperId, status: "parsing")
                let fileData: Data?
                let fileName = paper.originalFileName.isEmpty ? "\(paperId).pdf" : paper.originalFileName
                if paper.sourceType == "url_pdf" {
                    fileData = nil
                } else {
                    let pdfURL = await library.pdfURL(paperId)
                    guard FileManager.default.fileExists(atPath: pdfURL.path) else {
                        throw PipelineError("未找到原始 PDF，请检查源文件是否已一同迁移。", .pdfMissing)
                    }
                    fileData = try Data(contentsOf: pdfURL)
                }
                if mineruConfig.mode == "local" {
                    guard let fileData else {
                        throw PipelineError("本地 MinerU 模式仅支持直接上传的 PDF 文件", .pdfMissing)
                    }
                    progress[paperId] = "正在等待解析任务空位"
                    contentListURL = try await localParseGate.withPermit {
                        self.updateMinerUProgress(paperId: paperId, message: "本地 MinerU 正在解析 PDF")
                        return try await MinerUClient.runLocalPipeline(
                        fileData: fileData, fileName: fileName,
                        config: mineruConfig, outputDir: outputDir
                        )
                    }
                } else {
                    let sourceURL: String? = paper.sourceType == "url_pdf" ? await library.sourceURL(paperId: paperId) : nil
                    contentListURL = try await MinerUClient.runFullPipeline(
                        fileData: fileData, fileName: fileName,
                        pdfURL: sourceURL,
                        config: mineruConfig, outputDir: outputDir, forceNewTask: forceReparse,
                        submissionGate: cloudGate, waitForQueuedTask: true,
                        stateChanged: { [weak self] state in
                            await self?.updateCloudState(paperId: paperId, state: state)
                        },
                        progress: { [weak self] message in
                            await self?.updateMinerUProgress(paperId: paperId, message: message)
                        }
                        )
                }
            }
            guard let contentListURL else {
                throw PipelineError("MinerU 解析结果不包含可读取的论文内容", .parseEmpty)
            }
            try await library.setStatus(paperId: paperId, status: "parsed")

            // Step 2: 规范化为 Block 记录。
            try await library.setStatus(paperId: paperId, status: "normalizing")
            let rawBlocks = try MinerUClient.parseContentList(at: contentListURL, dataRoot: await library.dataRoot)
            guard !rawBlocks.isEmpty else {
                throw PipelineError("MinerU 解析结果不包含可读取的论文内容", .parseEmpty)
            }
            var blockRecords: [Block] = rawBlocks.enumerated().map { index, raw in
                Block(
                    id: PaperLibrary.blockId(paperId: paperId, order: index),
                    order: index,
                    kind: raw["kind"] as? String ?? "paragraph",
                    pageIdx: raw["page_idx"] as? Int,
                    bbox: raw["bbox"] as? [Double],
                    sectionTitle: raw["section_title"] as? String ?? "",
                    textOriginal: raw["text_original"] as? String ?? "",
                    textZh: "",
                    oneLiner: "",
                    keywords: [],
                    roleInNarrative: "",
                    imagePath: raw["image_path"] as? String ?? "",
                    captionOriginal: raw["caption_original"] as? String ?? "",
                    captionZh: "",
                    figureType: "",
                    coreTakeaways: [],
                    dataReadingNotes: "",
                    tableHtml: raw["table_html"] as? String ?? "",
                    latex: raw["latex"] as? String ?? "",
                    plainExplanation: "",
                    entityRefs: [],
                    headingLevel: raw["heading_level"] as? Int
                )
            }
            try await library.writeBlocks(paperId: paperId, blocks: blockRecords)

            // Step 2.5: 元数据识别。此处已有原文，失败也不影响后续；
            // 整步静默失败，绝不让一次网络抖动把论文变成 error。
            // 分类规则见 MetadataRecognition.shouldInterrupt（有测试背书）。
            do {
                try await recognizeMetadata(paperId: paperId, blocks: blockRecords)
            } catch {
                if MetadataRecognition.shouldInterrupt(error) { throw error }
            }

            // Step 3: 完整翻译、段落分析和全文总结。
            try await runAnalysis(
                paperId: paperId,
                title: paper.title,
                blocks: &blockRecords,
                resumePrevious: !forceReparse
            )
        } catch {
            await recordFailure(error, paperId: paperId)
        }
    }

    // MARK: - 重新翻译（复用 MinerU blocks）

    /// 识别 DOI / arXiv 并回填作者、年份、期刊。
    ///
    /// 这里只提供 IO 动作；**编排决策在 `MetadataRecognition`（core target 内，可测）**，
    /// 包括"标识符先于网络落库"、"manual 记录不写"、"仅 duplicatePaper 可中断"。
    private func recognizeMetadata(paperId: String, blocks: [Block]) async throws {
        let outcome = try await MetadataRecognition.run(
            blocks, actions: MetadataRecognition.actions(library: library, paperId: paperId)
        )
        if case .duplicate(let existing) = outcome {
            throw PipelineError("与已有论文《\(existing.displayTitle)》是同一篇（DOI / arXiv 相同，id \(existing.id)）",
                                .duplicatePaper)
        }
    }

    private func runRetranslate(paperId: String) async {
        guard let paper = await library.paper(id: paperId) else { return }
        do {
            try await waitForCredentials(paperId: paperId)
            let llmConfig = settings.llmConfig(for: .translation)
            guard llmConfig.isConfigured else {
                throw PipelineError("未配置可用的模型 API，请先在设置页保存并测试连接", .llmNotConfigured)
            }
            try await library.setStatus(paperId: paperId, status: "analyzing")
            var blocks = try await library.readBlocks(paperId: paperId)
            guard !blocks.isEmpty else {
                throw PipelineError("论文还没有可复用的解析段落，请使用重新解析", .parseEmpty)
            }
            try await runAnalysis(
                paperId: paperId,
                title: paper.title,
                blocks: &blocks
            )
        } catch {
            await recordFailure(error, paperId: paperId)
        }
    }

    private func runRecovery(paperId: String) async {
        do {
            let url = await library.analysesDir(paperId).appendingPathComponent("single_pass.json")
            let data = try Data(contentsOf: url)
            guard var log = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ["single_pass", "bounded_batches"].contains(log["mode"] as? String ?? ""), let raw = log["raw_response"] as? String, !raw.isEmpty else {
                throw PipelineError("没有已返回的全文分析可供恢复，请先完成全文处理。", .jsonParseFailed)
            }
            var blocks = try await library.readBlocks(paperId: paperId)
            let input = analysisBlocks(blocks)
            if let fingerprint = log["input_fingerprint"] as? String,
               fingerprint != AnalysisEngine.inputFingerprint(input) {
                throw PipelineError("解析原文已变化，不能恢复旧响应，请重新分析。", .jsonParseFailed)
            }
            try Task.checkCancellation()
            progress[paperId] = "正在本地恢复已返回结果，无需调用模型"
            let result = try AnalysisEngine.decodePaperResponse(raw, blocks: input)
            try await saveAnalysis(result, paperId: paperId, blocks: &blocks)
            log["error"] = ""
            log["state"] = "recovered"
            log["local_recovery"] = true
            try await library.writeAnalysisRaw(paperId: paperId, name: "single_pass.json", data: log)
        } catch { await recordFailure(error, paperId: paperId) }
    }

    private func analysisBlocks(_ blocks: [Block]) -> [[String: Any]] {
        blocks.map { block in
            ["id": block.id, "kind": block.kind, "text_original": block.textOriginal,
             "caption_original": block.captionOriginal, "latex": block.latex,
             "table_html": block.tableHtml, "section_title": block.sectionTitle]
        }
    }

    private func waitForCredentials(paperId: String) async throws {
        while settings.loading || settings.readingCredentials {
            progress[paperId] = "正在读取已保存的服务凭据"
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try Task.checkCancellation()
    }

    private func updateMinerUProgress(paperId: String, message: String) {
        guard !Task.isCancelled else { return }
        progress[paperId] = message
    }

    private func updateCloudState(paperId: String, state: String) {
        guard !Task.isCancelled else { return }
        cloudStates[paperId] = state
    }

    // MARK: - 全文分析

    private func runAnalysis(paperId: String, title: String, blocks: inout [Block], resumePrevious: Bool = false) async throws {
        let config = settings.llmConfig(for: .translation)
        try await library.setStatus(paperId: paperId, status: "analyzing")
        let input = analysisBlocks(blocks)
        progress[paperId] = "正在等待模型任务空位"
        try await llmGate.acquire()
        defer { Task { await llmGate.release() } }
        try Task.checkCancellation()
        let library = self.library
        // Manual Continue may reuse validated translation chunks. Retranslate
        // and Reparse intentionally start fresh.
        let resume: [String: Any]?
        if resumePrevious, let data = try? Data(contentsOf: await library.analysesDir(paperId).appendingPathComponent("single_pass.json")) {
            resume = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else { resume = nil }
        try await library.writeAnalysisRaw(paperId: paperId, name: "single_pass.json", data: [
            "mode": "single_pass", "model": config.model, "created_at": PaperLibrary.now(),
            "block_count": blocks.count, "state": "starting"
        ])
        let methodGroups = await library.listMethodGroups()
        let existingMethods = try await library.methodIndex()
        let result = try await AnalysisEngine.analyzePaper(
            llm: config, blocks: input, title: title, methodGroups: methodGroups, existingMethods: existingMethods,
            resumeLog: resume,
            progress: { [weak self] completed, total in
                await self?.updateProgress(paperId: paperId, completed: completed, total: total)
            },
            capture: { log in
                // 即使模型输出截断，也保存可诊断的原始响应，不再触发补译调用。
                try? await library.writeAnalysisRaw(paperId: paperId, name: "single_pass.json", data: log)
            }
        )
        try await saveAnalysis(result, paperId: paperId, blocks: &blocks)
    }

    private func saveAnalysis(_ result: AnalysisEngine.PaperAnalysis, paperId: String, blocks: inout [Block]) async throws {
        try Task.checkCancellation()
        progress[paperId] = "全文分析已返回，正在保存结果"
        let methods = try AnalysisEngine.resolveMethods(result.methods, groups: await library.listMethodGroups(), existing: try await library.methodIndex())
        let entities = methods.map { item in
            MethodEntity(id: PaperLibrary.newId(), canonicalKey: AnalysisEngine.asString(item["canonical_key"]),
                         name: AnalysisEngine.asString(item["name"]), category: AnalysisEngine.asString(item["category"]),
                         definitionZh: AnalysisEngine.asString(item["definition_zh"]), blockRefs: item["refs"] as? [String] ?? [])
        }
        for i in blocks.indices {
            let node = result.nodes[i]
            let translation = AnalysisEngine.asString(node["zh"])
            switch blocks[i].kind {
            case "figure", "table":
                blocks[i].captionZh = translation
                blocks[i].coreTakeaways = [AnalysisEngine.asString(node["note"])]
            case "equation": blocks[i].plainExplanation = translation
            default: blocks[i].textZh = translation
            }
            blocks[i].oneLiner = AnalysisEngine.asString(node["note"])
            blocks[i].roleInNarrative = AnalysisEngine.asString(node["role"])
            blocks[i].entityRefs = entities.filter { $0.blockRefs.contains(blocks[i].id) }.map(\.id)
            blocks[i].keywords = Array(entities.filter { $0.blockRefs.contains(blocks[i].id) }.map(\.name).prefix(3))
        }
        try await library.writeBlocks(paperId: paperId, blocks: blocks)
        try await library.writeEntities(paperId: paperId, entities: entities)
        let metadata = result.paper
        try await library.updatePaper { record in
            guard record.id == paperId else { return }
            AnalysisEngine.applyPaperSummary(metadata, to: &record)
        }
        try Task.checkCancellation()
        try await library.setStatus(paperId: paperId, status: "ready")
    }

    private func updateProgress(paperId: String, completed: Int, total: Int) {
        guard !Task.isCancelled else { return }
        nodeProgress[paperId] = NodeProgress(completed: min(completed, total), total: total)
        progress[paperId] = completed == 0
            ? "正在翻译与分析全文，等待模型返回"
            : "全文翻译与分析：\(completed) / \(total) 个节点"
    }
}
