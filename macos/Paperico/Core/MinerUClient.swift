import Foundation

/// MinerU 云端/本地 Gradio 解析客户端(移植 backend/app/services/mineru.py)。
///
/// 云端流程:申请签名上传地址(/file-urls/batch)→ PUT 上传(自动开跑)
/// → 轮询(/extract-results/batch/{id})→ 下载结果 ZIP 解包 → 解析 content_list.json。
/// URL 任务:POST /extract/task → 轮询 /extract/task/{id}。
enum MinerUClient {

    struct Config: Sendable {
        var mode: String            // cloud | local
        var baseUrl: String
        var localUrl: String
        var token: String
        var options: MinerUDefaultOptions
    }

    struct SubmitResult: Codable, Sendable {
        var taskId: String
        var batchId: String
        var pollType: String        // "batch" | "task"
    }

    struct PollStatus: Sendable {
        var status: String          // pending | running | done | failed
        var zipURL: String
        var error: String
        var extractedPages: Int? = nil
        var totalPages: Int? = nil
        var traceID: String = ""
    }

    private actor PollObservation {
        var state: String?
        private var activeAt: ContinuousClock.Instant?
        func update(_ state: String) {
            self.state = state
            if ["running", "converting"].contains(state), activeAt == nil { activeAt = .now }
        }
        func deadline(start: ContinuousClock.Instant, budget: TimeInterval) -> ContinuousClock.Instant {
            (activeAt ?? start).advanced(by: .seconds(max(0, budget)))
        }
    }

    private struct CloudTaskCheckpoint: Codable {
        let baseURL: String
        let options: MinerUDefaultOptions
        let submitted: SubmitResult
        var completed: Bool? = nil
    }

    static let gradioFunction = "convert_to_markdown_stream"

    // MARK: - 提交

    static func submitBatch(
        fileData: Data, fileName: String, config: Config, session: URLSession = .shared
    ) async throws -> SubmitResult {
        let payload: [String: Any] = [
            "files": [[
                "name": fileName,
                "data_id": "paperico-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())",
                "is_ocr": config.options.isOcr,
            ]],
            "enable_formula": config.options.enableFormula,
            "enable_table": config.options.enableTable,
            "model_version": config.options.modelBackend,
        ]
        let body = try await postJSON(path: "/file-urls/batch", payload: payload, config: config, timeout: 120, session: session)
        let data = (body["data"] as? [String: Any]) ?? body
        let fileURLs = data["file_urls"] as? [String] ?? []
        let batchId = data["batch_id"] as? String ?? ""
        guard let uploadURL = fileURLs.first, !uploadURL.isEmpty, !batchId.isEmpty else {
            throw MinerUServiceError("MinerU did not return an upload URL and batch ID", .mineruSubmitFailed)
        }

        // 上传成功即自动开始解析任务。
        guard let url = URL(string: uploadURL) else {
            throw MinerUServiceError("MinerU 上传地址无法解析", .mineruSubmitFailed)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        // The presigned OSS URL is signed without Content-Type. Adding a media
        // type changes the signature and causes HTTP 403 SignatureDoesNotMatch.
        // Do not forward API authorization or JSON headers to object storage.
        request.httpBody = fileData
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MinerUServiceError("MinerU 文件上传失败 (HTTP \(status))", .mineruSubmitFailed)
        }
        return SubmitResult(taskId: "", batchId: batchId, pollType: "batch")
    }

    static func submitURL(_ url: String, config: Config, session: URLSession = .shared) async throws -> SubmitResult {
        let payload: [String: Any] = [
            "url": url,
            "is_ocr": config.options.isOcr,
            "enable_formula": config.options.enableFormula,
            "enable_table": config.options.enableTable,
            "model_version": config.options.modelBackend,
        ]
        let body = try await postJSON(path: "/extract/task", payload: payload, config: config, timeout: 60, session: session)
        let data = (body["data"] as? [String: Any]) ?? body
        let taskId = data["task_id"] as? String ?? ""
        guard !taskId.isEmpty else {
            throw MinerUServiceError("MinerU 未返回任务 ID", .mineruSubmitFailed)
        }
        return SubmitResult(taskId: taskId, batchId: "", pollType: "task")
    }

    // MARK: - 轮询

    static func poll(submit: SubmitResult, config: Config, session: URLSession = .shared) async throws -> PollStatus {
        if submit.pollType == "batch" {
            let body = try await getJSON(path: "/extract-results/batch/\(submit.batchId)", config: config, timeout: 30, session: session)
            guard let data = body["data"] as? [String: Any],
                  let results = data["extract_result"] as? [[String: Any]] else {
                throw MinerUServiceError("MinerU 未返回批次状态，不能继续等待。", .mineruParseFailed)
            }
            guard let item = results.first else {
                return PollStatus(status: "pending", zipURL: "", error: "")
            }
            return try decodePollStatus(item, traceID: body["trace_id"] as? String ?? "")
        }
        let body = try await getJSON(path: "/extract/task/\(submit.taskId)", config: config, timeout: 30, session: session)
        let data = (body["data"] as? [String: Any]) ?? body
        return try decodePollStatus(data, traceID: body["trace_id"] as? String ?? "")
    }

    private static func decodePollStatus(_ data: [String: Any], traceID: String) throws -> PollStatus {
        guard let state = data["state"] as? String,
              ["waiting-file", "uploading", "pending", "running", "converting", "done", "failed"].contains(state) else {
            throw MinerUServiceError("MinerU 返回了无效的任务状态，不能继续等待。", .mineruParseFailed)
        }
        let pages = data["extract_progress"] as? [String: Any]
        return PollStatus(
            status: state,
            zipURL: data["full_zip_url"] as? String ?? "",
            error: data["err_msg"] as? String ?? "",
            extractedPages: pages?["extracted_pages"] as? Int,
            totalPages: pages?["total_pages"] as? Int,
            traceID: traceID
        )
    }

    /// 完整管线:提交 → 轮询至完成 → 下载解包 → 返回 content_list 文件。
    static func runFullPipeline(
        fileData: Data?, fileName: String, pdfURL: String?, config: Config,
        outputDir: URL,
        pollInterval: TimeInterval = 3.0, maxWait: TimeInterval = 600.0,
        forceNewTask: Bool = false, session: URLSession = .shared,
        submissionGate: JobGate? = nil, waitForQueuedTask: Bool = false, queuedRetryInterval: TimeInterval = 15,
        stateChanged: @escaping @Sendable (String) async -> Void = { _ in },
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let checkpointURL = outputDir.appendingPathComponent("cloud-task.json")
        let checkpoint = try? JSONDecoder().decode(CloudTaskCheckpoint.self, from: Data(contentsOf: checkpointURL))
        let submitted: SubmitResult
        if !forceNewTask, let checkpoint,
           checkpoint.baseURL == normalizedBase(config.baseUrl), checkpoint.options == config.options {
            submitted = checkpoint.submitted
            await progress("正在继续已有的 MinerU 云端任务")
        } else {
            let submit = {
                await progress("正在提交并上传 PDF 到 MinerU")
                if let pdfURL {
                    return try await submitURL(pdfURL, config: config, session: session)
                } else if let fileData {
                    return try await submitBatch(fileData: fileData, fileName: fileName, config: config, session: session)
                } else {
                    throw MinerUServiceError("MinerU requires either file_path or pdf_url", .mineruSubmitFailed)
                }
            }
            if let submissionGate {
                await progress("正在等待上传任务空位")
                submitted = try await submissionGate.withPermit(submit)
            } else { submitted = try await submit() }
            try LibraryFiles.writeJSON(CloudTaskCheckpoint(baseURL: normalizedBase(config.baseUrl), options: config.options,
                                                          submitted: submitted), to: checkpointURL, encoder: JSONEncoder())
        }
        var status: PollStatus
        while true {
            do {
                status = try await waitForResult(submit: submitted, config: config, session: session,
                                                pollInterval: pollInterval, maxWait: maxWait,
                                                diagnosticURL: outputDir.appendingPathComponent("cloud-status.json"),
                                                stateChanged: stateChanged, progress: progress)
                break
            } catch let error as MinerUServiceError where waitForQueuedTask && error.errorCode == .mineruTimeout
                && error.lastState == "pending" {
                // A valid cloud job can wait longer than the local observation
                // window. Continue polling its ID without uploading again.
                await progress("MinerU 云端仍在排队，尚未开始解析；将自动继续等待")
                try await Task.sleep(for: .seconds(max(0.001, queuedRetryInterval)))
            }
        }
        if status.status == "failed" {
            try? FileManager.default.removeItem(at: checkpointURL)
            throw MinerUServiceError("MinerU 解析失败：\(status.error.isEmpty ? "未知错误" : status.error)", .mineruParseFailed)
        }
        await progress("MinerU 解析完成，正在下载结果")
        let contentList = try await downloadAndExtractResults(zipURL: status.zipURL, outputDir: outputDir, session: session)
        try LibraryFiles.writeJSON(CloudTaskCheckpoint(baseURL: normalizedBase(config.baseUrl), options: config.options,
                                                      submitted: submitted, completed: true), to: checkpointURL, encoder: JSONEncoder())
        return contentList
    }

    /// Race polling against a real deadline, including time spent in requests.
    /// Cancellation also cancels an in-flight URLSession request.
    static func waitForResult(
        submit: SubmitResult, config: Config, session: URLSession = .shared,
        pollInterval: TimeInterval = 3, maxWait: TimeInterval = 600,
        diagnosticURL: URL? = nil,
        stateChanged: @escaping @Sendable (String) async -> Void = { _ in },
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> PollStatus {
        let observation = PollObservation()
        return try await withThrowingTaskGroup(of: PollStatus.self) { group in
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    let status = try await poll(submit: submit, config: config, session: session)
                    await observation.update(status.status)
                    await stateChanged(status.status)
                    if let diagnosticURL {
                        var record: [String: Any] = ["updated_at": PaperLibrary.now(), "batch_id": submit.batchId,
                            "task_id": submit.taskId, "backend": config.options.modelBackend, "state": status.status,
                            "error": status.error, "trace_id": status.traceID, "has_result_url": !status.zipURL.isEmpty]
                        if let pages = status.extractedPages { record["extracted_pages"] = pages }
                        if let pages = status.totalPages { record["total_pages"] = pages }
                        try LibraryFiles.writeJSONAny(record, to: diagnosticURL)
                    }
                    if status.status == "done" || status.status == "failed" { return status }
                    let message: String
                    switch status.status {
                    case "waiting-file": message = "MinerU 等待确认文件上传"
                    case "uploading": message = "MinerU 正在下载源文件"
                    case "pending": message = "MinerU 云端排队中"
                    case "converting": message = "MinerU 正在转换解析结果"
                    default:
                        if let done = status.extractedPages, let total = status.totalPages {
                            message = "MinerU 正在解析：\(done) / \(total) 页"
                        } else { message = "MinerU 正在解析 PDF" }
                    }
                    await progress(message)
                    let interval = status.status == "pending" ? max(15, pollInterval) : max(0.01, pollInterval)
                    try await Task.sleep(for: .seconds(interval))
                }
            }
            group.addTask {
                let start = ContinuousClock.now
                while true {
                    let deadline = await observation.deadline(start: start, budget: maxWait)
                    try await Task.sleep(until: deadline, clock: .continuous)
                    // Once cloud parsing starts, it receives its own processing
                    // budget; time already spent in the queue is not subtracted.
                    if await observation.deadline(start: start, budget: maxWait) <= .now { break }
                }
                let state = await observation.state
                let message = state == "pending"
                    ? "MinerU 云端仍在排队，尚未开始解析。可继续已有任务，无需重新上传 PDF。"
                    : "MinerU 等待超时（最后状态：\(state ?? "未收到响应")），可继续已有任务。"
                throw MinerUServiceError(message, .mineruTimeout, lastState: state)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// 下载结果 ZIP 并解包到 outputDir,返回定位到的 content_list.json。
    static func downloadAndExtractResults(zipURL: String, outputDir: URL, session: URLSession = .shared) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let resultID = UUID().uuidString
        let incoming = outputDir.appendingPathComponent(".incoming-\(resultID)", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: incoming) }
        let zipPath = incoming.appendingPathComponent("result.zip")

        guard let url = URL(string: zipURL), !zipURL.isEmpty else {
            throw MinerUServiceError("MinerU 结果中缺少结果 ZIP 文件", .mineruParseFailed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MinerUServiceError("MinerU 结果下载失败 (HTTP \(status))", .mineruParseFailed)
        }
        try data.write(to: zipPath, options: .atomic)
        do {
            try ZipArchive.extract(zipURL: zipPath, to: incoming)
        } catch {
            throw MinerUServiceError("MinerU 结果解包失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))", .mineruParseFailed)
        }
        try? fm.removeItem(at: zipPath)

        // MinerU v4 的条目名常带任务 UUID 前缀,如 "<task_id>_content_list.json";优先扁平 v1 结构。
        guard let contentList = findContentList(in: incoming) else {
            throw MinerUServiceError("MinerU 结果不包含 content_list.json", .mineruParseFailed)
        }
        // Enumeration can resolve /var → /private/var (or a symlinked data root).
        // Strip the prefix only after resolving both sides to the same spelling.
        let incomingPath = incoming.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let contentPath = contentList.standardizedFileURL.resolvingSymlinksInPath().path
        guard contentPath.hasPrefix(incomingPath) else {
            throw MinerUServiceError("MinerU 内容清单位于结果目录之外", .mineruParseFailed)
        }
        let relativePath = String(contentPath.dropFirst(incomingPath.count))
        let resultDir = outputDir.appendingPathComponent("result-\(resultID)", isDirectory: true)
        try fm.moveItem(at: incoming, to: resultDir)
        let finalURL = resultDir.appendingPathComponent(relativePath)
        try LibraryFiles.writeData(Data("\(resultDir.lastPathComponent)/\(relativePath)".utf8),
                                   to: outputDir.appendingPathComponent("latest-content-list.txt"))
        return finalURL
    }

    /// 在输出目录中定位 MinerU 的扁平 content list(排除 *_content_list_v2.json)。
    static func findContentList(in directory: URL) -> URL? {
        // A newly submitted reparse supersedes older files. Until that task has
        // downloaded successfully, "continue" must resume it rather than read
        // an earlier parse that happens to be left in the same paper directory.
        let checkpointURL = directory.appendingPathComponent("cloud-task.json")
        if let checkpoint = try? JSONDecoder().decode(CloudTaskCheckpoint.self, from: Data(contentsOf: checkpointURL)),
           checkpoint.completed != true { return nil }
        // A retry must read the newest successful download, even if an older
        // archive had a shallower path or an alphabetically earlier task ID.
        if let path = try? String(contentsOf: directory.appendingPathComponent("latest-content-list.txt"), encoding: .utf8) {
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            let candidate = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            if candidate.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        var candidates: [URL] = []
        for case let file as URL in enumerator {
            if file.lastPathComponent.contains("content_list.json"),
               !file.lastPathComponent.hasSuffix("_content_list_v2.json") {
                candidates.append(file)
            }
        }
        // 与后端一致:按相对路径深度与名称排序取最浅者。
        candidates.sort { a, b in
            let da = a.pathComponents.count, db = b.pathComponents.count
            return da == db ? a.lastPathComponent < b.lastPathComponent : da < db
        }
        return candidates.first
    }

    // MARK: - content_list 解析

    /// 把 MinerU content_list.json 解析成内部 Block 字典数组(逐行对齐 parse_content_list)。
    /// `dataRoot` 用于把图片绝对路径折叠成相对引用(Block.imagePath)。
    static func parseContentList(at contentListURL: URL, dataRoot: URL) throws -> [[String: Any]] {
        let data = try Data(contentsOf: contentListURL)
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw MinerUServiceError("MinerU content list must be a JSON array", .jsonParseFailed)
        }

        let root = dataRoot.standardizedFileURL.path
        let contentDir = contentListURL.deletingLastPathComponent().standardizedFileURL

        var blocks: [[String: Any]] = []
        var order = 0
        var currentSection = ""

        let ignoredTypes: Set<String> = ["header", "footer", "page_number", "aside_text"]
        for item in items {
            guard let item = item as? [String: Any] else { continue }
            let itemType = item["type"] as? String ?? "text"
            if ignoredTypes.contains(itemType) {
                // Journals put their own DOI in the first-page header/footer.
                // Preserve only identifier-bearing publication text there, while
                // continuing to discard recurring page furniture elsewhere.
                let ids = PaperMetadata.extractIdentifiers(publicationTexts: [flattenText(item["text"])])
                guard ["header", "footer"].contains(itemType),
                      (item["page_idx"] as? NSNumber)?.intValue == 0,
                      ids.doi != nil || ids.arxivId != nil else { continue }
            }
            if itemType == "list", (item["sub_type"] as? String) == "ref_text" { continue }

            var text = flattenText(item["text"])
            if itemType == "list" {
                let bullets = (item["list_items"] as? [Any] ?? []).compactMap { raw -> String? in
                    let part = flattenText(raw)
                    return part.isEmpty ? nil : "• \(part)"
                }
                text = bullets.joined(separator: "\n")
            }
            let textLevel = (item["text_level"] as? Int) ?? (item["text_level"] as? Double).map { Int($0) } ?? 0
            let pageIdx = (item["page_idx"] as? Int) ?? (item["page_idx"] as? Double).map { Int($0) }
            let bbox = item["bbox"] as? [Double] ?? (item["bbox"] as? [NSNumber])?.map { $0.doubleValue }
            let imgPath = item["img_path"] as? String ?? ""
            let tableBody = item["table_body"] as? String ?? ""
            let caption = flattenText(
                item["image_caption"] ?? item["chart_caption"] ?? item["table_caption"] ?? item["caption"]
            )

            let kind: String
            if itemType == "title" || textLevel > 0 {
                kind = "section_heading"
                currentSection = text
            } else if itemType == "image" || itemType == "chart" {
                kind = "figure"
            } else if itemType == "table" {
                kind = "table"
            } else if itemType == "equation" {
                kind = "equation"
            } else if itemType == "list" {
                kind = "list_item"
            } else {
                kind = "paragraph"
            }

            // 装饰性图标与空版式块不是有效阅读节点;图表仅在带图注/表格体时保留。
            if (kind == "figure" || kind == "table") && caption.isEmpty && tableBody.isEmpty { continue }
            if kind != "figure" && kind != "table" && text.isEmpty { continue }

            // 图片记为相对数据根目录的引用,与后端 storage reference 语义一致。
            var servedImagePath = ""
            if !imgPath.isEmpty {
                let absolute = contentDir.appendingPathComponent(imgPath).standardizedFileURL.path
                if absolute.hasPrefix(root + "/") {
                    servedImagePath = String(absolute.dropFirst(root.count + 1))
                }
            }

            var block: [String: Any] = [
                "order": order,
                "kind": kind,
                "section_title": currentSection,
                "text_original": (kind == "figure" || kind == "table") ? "" : text,
                "caption_original": (kind == "figure" || kind == "table") ? caption : "",
                "image_path": servedImagePath,
                "table_html": tableBody,
                "latex": kind == "equation" ? text : "",
            ]
            if let pageIdx { block["page_idx"] = pageIdx }
            if kind == "section_heading" { block["heading_level"] = max(1, textLevel) }
            if let bbox { block["bbox"] = bbox }
            blocks.append(block)
            order += 1
        }
        return blocks
    }

    /// 展开图注/列表片段(对齐 _flatten_text 的 v1/v2 兼容形状)。
    static func flattenText(_ value: Any?) -> String {
        guard let value else { return "" }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let list = value as? [Any] {
            return list.compactMap { part -> String? in
                let flattened = flattenText(part)
                return flattened.isEmpty ? nil : flattened
            }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
        if let dict = value as? [String: Any] {
            for key in ["text", "content", "value"] {
                if let nested = dict[key] { return flattenText(nested) }
            }
        }
        return ""
    }

    // MARK: - 本地 Gradio 部署

    /// Gradio 语言下拉存的是完整标签;Paperico 短码映射(对齐 GRADIO_LANGUAGE_LABELS)。
    static func gradioLanguageLabel(_ language: String) -> String {
        language == "korean"
            ? "korean (Korean, English)"
            : "ch (Chinese, English, Japanese, Chinese Traditional, Latin)"
    }

    /// 走用户自部署的 mineru-gradio 服务(单条 SSE 流内同步完成解析)。
    static func runLocalPipeline(
        fileData: Data, fileName: String, config: Config, outputDir: URL
    ) async throws -> URL {
        let checkpointURL = outputDir.appendingPathComponent("cloud-task.json")
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            try FileManager.default.removeItem(at: checkpointURL)
        }
        let base = (config.localUrl.isEmpty ? "http://127.0.0.1:7860" : config.localUrl).trimmingCharacters(in: .whitespaces)
        var backend = config.options.modelBackend.isEmpty ? "pipeline" : config.options.modelBackend
        if backend == "vlm" { backend = "vlm-engine" }

        // 1) multipart 上传,服务器返回暂存路径。
        let boundary = "paperico-\(UUID().uuidString)"
        var uploadRequest = URLRequest(url: try ServiceURL.endpoint(base: base, path: "/gradio_api/upload"))
        uploadRequest.httpMethod = "POST"
        uploadRequest.timeoutInterval = 300
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        uploadRequest.httpBody = body

        let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        guard let uploadHTTP = uploadResponse as? HTTPURLResponse, (200..<300).contains(uploadHTTP.statusCode),
              let serverPaths = try? JSONSerialization.jsonObject(with: uploadData) as? [String],
              let serverPath = serverPaths.first, !serverPath.isEmpty else {
            throw MinerUServiceError("本地 MinerU 上传失败：未返回服务器文件路径", .mineruSubmitFailed)
        }

        // 2) 发起解析调用,拿 event_id。
        let payload: [String: Any] = ["data": [
            ["path": serverPath, "meta": ["_type": "gradio.FileData"]],
            1000,                                        // end_pages
            config.options.isOcr,
            config.options.enableFormula,
            config.options.enableTable,
            true,                                        // image_analysis
            "medium",                                    // effort
            gradioLanguageLabel("en"),
            backend,
            "http://localhost:30000",                    // vlm_server_url
        ]]
        var callRequest = URLRequest(url: try ServiceURL.endpoint(base: base, path: "/gradio_api/call/\(gradioFunction)"))
        callRequest.httpMethod = "POST"
        callRequest.timeoutInterval = 60
        callRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        callRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (callData, callResponse) = try await URLSession.shared.data(for: callRequest)
        guard let callHTTP = callResponse as? HTTPURLResponse, (200..<300).contains(callHTTP.statusCode),
              let call = try? JSONSerialization.jsonObject(with: callData) as? [String: Any],
              let eventId = call["event_id"] as? String, !eventId.isEmpty else {
            throw MinerUServiceError("本地 MinerU 未返回 event_id", .mineruSubmitFailed)
        }

        // 3) SSE 流里等 complete 事件,取结果 ZIP。
        guard let streamURL = URL(string: base + "/gradio_api/call/\(gradioFunction)/\(eventId)") else {
            throw MinerUServiceError("本地 MinerU 结果地址无法解析", .mineruSubmitFailed)
        }
        let (bytes, streamResponse) = try await URLSession.shared.bytes(for: URLRequest(url: streamURL))
        guard let streamHTTP = streamResponse as? HTTPURLResponse, (200..<300).contains(streamHTTP.statusCode) else {
            throw MinerUServiceError("本地 MinerU 解析流连接失败", .mineruParseFailed)
        }
        var eventName = ""
        var zipURL = ""
        do {
            for try await line in bytes.lines {
                if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if eventName == "complete" {
                        if let parsed = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [Any],
                           parsed.count >= 2,
                           let zipInfo = parsed[1] as? [String: Any],
                           let url = zipInfo["url"] as? String, !url.isEmpty {
                            zipURL = url
                            if zipURL.hasPrefix("/") { zipURL = base + zipURL }
                        }
                        break
                    }
                    if eventName == "error" {
                        let detail = data == "null" ? "" : data
                        throw MinerUServiceError("本地 MinerU 解析失败\(detail.isEmpty ? "" : ": \(detail)")", .mineruParseFailed)
                    }
                }
            }
        } catch let error as MinerUServiceError {
            throw error
        } catch {
            throw MinerUServiceError("本地 MinerU 解析流中断：\(error.localizedDescription)", .mineruParseFailed)
        }
        guard !zipURL.isEmpty else {
            throw MinerUServiceError("本地 MinerU 结果中缺少结果 ZIP 文件", .mineruParseFailed)
        }
        return try await downloadAndExtractResults(zipURL: zipURL, outputDir: outputDir)
    }

    // MARK: - 连通性探测(移植 settings_api.py 的 test-mineru)

    static func testMinerU(config: Config, savedToken: String) async -> (success: Bool, message: String) {
        if config.mode == "local" {
            let base = (config.localUrl.isEmpty ? "http://127.0.0.1:7860" : config.localUrl).trimmingCharacters(in: .whitespaces)
            do {
                var request = URLRequest(url: try ServiceURL.endpoint(base: base, path: "/gradio_api/info"))
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return (false, "本地 MinerU 连接失败： 服务未响应")
                }
                if let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let endpoints = info["named_endpoints"] as? [String: Any],
                   endpoints["/\(gradioFunction)"] != nil {
                    return (true, "本地 MinerU 服务连接成功")
                }
                return (false, "服务已响应，但不是 MinerU Gradio 接口")
            } catch {
                return (false, "本地 MinerU 连接失败： \(error.localizedDescription)")
            }
        }

        let token = config.token.isEmpty ? savedToken : config.token
        guard !token.isEmpty else {
            return (false, "尚未保存可用的 MinerU Token")
        }
        let base = normalizedBase(config.baseUrl.isEmpty ? "https://mineru.net/api/v4" : config.baseUrl)
        guard let url = try? ServiceURL.endpoint(base: base, path: "/extract/task/__paperico_connection_test__") else {
            return (false, "MinerU 服务地址无效，请填写完整的 HTTP 地址")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "连接失败： 服务响应无效")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                return (false, "认证失败 (HTTP \(http.statusCode))，请检查 Token")
            }
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = payload["code"] {
                let codeText = String(describing: code)
                if codeText == "A0202" || codeText == "A0211" {
                    return (false, "认证失败 (\(codeText))，请检查或更新 Token")
                }
            }
            if http.statusCode < 500 {
                return (true, "MinerU Token 有效，服务连接成功")
            }
            return (false, "MinerU 服务异常 (HTTP \(http.statusCode))")
        } catch {
            return (false, "连接失败： \(error.localizedDescription)")
        }
    }

    // MARK: - HTTP 小工具

    private static func normalizedBase(_ base: String) -> String {
        var normalized = base.trimmingCharacters(in: .whitespaces)
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized
    }

    private static func request(path: String, config: Config, timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: normalizedBase(config.baseUrl) + path) else {
            throw MinerUServiceError("MinerU 地址无法解析：\(path)", .mineruSubmitFailed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func postJSON(path: String, payload: [String: Any], config: Config, timeout: TimeInterval, session: URLSession = .shared) async throws -> [String: Any] {
        var request = try request(path: path, config: config, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await execute(request: request, session: session)
    }

    private static func getJSON(path: String, config: Config, timeout: TimeInterval, session: URLSession = .shared) async throws -> [String: Any] {
        try await execute(request: request(path: path, config: config, timeout: timeout), session: session)
    }

    private static func execute(request: URLRequest, session: URLSession = .shared) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MinerUServiceError("MinerU 服务响应无效", .mineruSubmitFailed)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MinerUServiceError("MinerU 服务返回 HTTP \(http.statusCode)", .mineruSubmitFailed)
        }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // MinerU 业务错误用 body.code 表达,HTTP 仍是 200(对齐 _raise_api_error)。
        if let code = payload["code"] {
            let codeText: String
            if let number = code as? NSNumber { codeText = number.intValue == 0 ? "0" : String(describing: code) }
            else if let text = code as? String { codeText = text }
            else { codeText = "0" }
            if codeText != "0" && !codeText.isEmpty {
                let msg = payload["msg"] as? String ?? "unknown error"
                throw MinerUServiceError("MinerU API error \(codeText): \(msg)", .mineruSubmitFailed)
            }
        }
        return payload
    }
}
