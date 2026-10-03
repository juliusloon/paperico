import Foundation

// MARK: - 稳定错误码(与 backend/app/core/status.py 同名同义)

enum ErrorCode: String, Sendable {
    case mineruNotConfigured = "MINERU_NOT_CONFIGURED"
    case mineruTimeout = "MINERU_TIMEOUT"
    case mineruSubmitFailed = "MINERU_SUBMIT_FAILED"
    case mineruParseFailed = "MINERU_PARSE_FAILED"
    case llmNotConfigured = "LLM_NOT_CONFIGURED"
    case llmCallFailed = "LLM_CALL_FAILED"
    case jsonParseFailed = "JSON_PARSE_FAILED"
    case pdfMissing = "PDF_MISSING"
    case parseEmpty = "PARSE_EMPTY"
    case interruptedByRestart = "INTERRUPTED_BY_RESTART"
    case internalError = "INTERNAL"
    case storageFailed = "STORAGE_FAILED"
    case duplicatePaper = "DUPLICATE_PAPER"
    case cancelled = "CANCELLED"
}

/// 管线失败:携带稳定 ErrorCode,展示文本面向人。
struct PipelineError: LocalizedError, Sendable {
    let message: String
    let errorCode: ErrorCode

    init(_ message: String, _ code: ErrorCode = .internalError) {
        self.message = message
        self.errorCode = code
    }

    var errorDescription: String? { message }
}

struct MinerUServiceError: LocalizedError, Sendable {
    let message: String
    let errorCode: ErrorCode

    init(_ message: String, _ code: ErrorCode = .mineruParseFailed) {
        self.message = message
        self.errorCode = code
    }

    var errorDescription: String? { message }
}

struct LLMServiceError: LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

// MARK: - UI 层错误包装

/// 与旧 ApiFailure 同名兼容:stores/页面用它把任意错误转成展示文本。
/// 本应用现在直连模型服务与 MinerU,超时/断网文案按对应服务表述,不再出现"服务器"。
enum ApiFailure: LocalizedError, Sendable {
    case network(String)
    case timeout
    case api(ApiError)

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .timeout: return "请求超时，请重试。后台论文处理不会因此中断。"
        case .api(let error): return error.errorDescription
        }
    }

    static func wrap(_ error: Error) -> ApiFailure {
        if let failure = error as? ApiFailure { return failure }
        if let pipeline = error as? PipelineError { return .network(pipeline.message) }
        if let service = error as? MinerUServiceError { return .network(service.message) }
        if let llm = error as? LLMServiceError { return .network(llm.message) }
        if let apiError = error as? ApiError { return .api(apiError) }
        if let localized = error as? LocalizedError, let text = localized.errorDescription, !text.isEmpty {
            return .network(text)
        }
        if let urlError = error as? URLError {
            if urlError.code == .timedOut { return .timeout }
            if urlError.code == .cancelled { return .network("操作已取消") }
            return .network(urlError.localizedDescription)
        }
        return .network(error.localizedDescription)
    }
}

struct ApiError: LocalizedError, Sendable {
    let statusCode: Int
    let message: String

    var errorDescription: String? { "\(statusCode): \(message)" }
}
