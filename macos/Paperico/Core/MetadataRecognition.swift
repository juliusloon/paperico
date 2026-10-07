import Foundation

/// 元数据识别这一步的**编排决策**，抽出来单独测。
///
/// 之前这段逻辑内联在 `PaperPipeline.recognizeMetadata`（app-only 文件，不在 SwiftPM
/// target 内），于是最需要测试的三条业务规则没有任何测试背书：
///
/// 1. 标识符先落库、**在网络查询之前**——从原文读到的信息不该依赖网络；
/// 2. 只有 `duplicatePaper`（确定是同一篇论文）允许中断管线，其余一律静默放过；
/// 3. `manual` 记录既不写标识符也不写查询结果。
///
/// 这里全部是纯计算 +闭包注入，因此可在 `PapericoCoreTests` 内完整覆盖。
/// `PaperPipeline` 只负责提供 IO 动作，本文件不碰任何网络或磁盘。
enum MetadataRecognition {

    /// 识别步骤的动作。管线注入真实实现，测试注入探针。
    ///
    /// 写动作都是`throws`：落盘失败必须能上报，而不是被静默当成"识别失败"。
    struct Actions {
        /// 已解析的论文 ID。
        let paperId: String
        /// 同一次库操作中写入标识符并判断重复，不允许在两步间释放 actor。
        let registerIdentifiers: (PaperMetadata.Identifiers, String) async throws -> PaperListItem?
        /// 联网查询元数据；任何失败返回 nil。
        let lookup: (PaperMetadata.Identifiers) async -> PaperMetadata.Metadata?
        /// 写入查询结果。
        let applyMetadata: (PaperMetadata.Metadata) async throws -> Void
        /// 当前记录的 `metaSource`；`manual` 时不写任何自动字段。
        let metaSource: () async -> String
    }

    enum Outcome: Equatable {
        /// 无可识别标识符，未做任何事。
        case noIdentifier
        /// 识别完成（无论查询是否成功）。
        case recognized
        /// 已有同 DOI / arXiv 的论文——确定性冲突，必须让用户看到。
        case duplicate(PaperListItem)
    }

    /// 管线级失败分类：哪些错误可以上报给用户，哪些必须吞掉。
    ///
    /// 识别是锦上添花，解析与翻译才是主路径；一次 Crossref 抖动不该让本来
    /// 能读懂的论文变成 error。
    static func shouldInterrupt(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? PipelineError)?.errorCode == .duplicatePaper
    }

    static func run(_ blocks: [Block], actions: Actions) async throws -> Outcome {
        let ids = PaperMetadata.extractIdentifiers(from: blocks)
        guard ids.doi != nil || ids.arxivId != nil else { return .noIdentifier }

        // 用户手改过的记录是权威值：既不写标识符，也不写查询结果。
        guard await actions.metaSource() != MetaSource.manual else { return .noIdentifier }

        // 标识符先落库。网络失败也要留痕——它是从原文里读出来的，不是查出来的。
        if let duplicate = try await actions.registerIdentifiers(ids, actions.paperId) {
            return .duplicate(duplicate)
        }
        guard let metadata = await actions.lookup(ids) else { return .recognized }
        try await actions.applyMetadata(metadata)
        return .recognized
    }
}
