import Foundation

enum PaperStatus: String, Hashable, Sendable {
    case uploaded, parsing, parsed, normalizing, analyzing, reducing, ready, error
    case unknown

    init(raw: String) {
        self = PaperStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .uploaded: return "待解析"
        case .parsing: return "解析中"
        case .parsed: return "已解析"
        case .normalizing: return "清洗中"
        case .analyzing: return "分析中"
        case .reducing: return "归纳中"
        case .ready: return "已就绪"
        case .error: return "出错"
        case .unknown: return "未知"
        }
    }

    /// ReadingArea.STATUS_COPY — shown on the preparing stage.
    var processingCopy: String? {
        switch self {
        case .uploaded: return "等待开始"
        case .parsing: return "MinerU 正在恢复版面结构"
        case .parsed: return "结构解析完成"
        case .normalizing: return "正在整理文本块"
        case .analyzing: return "正在翻译并提炼段落"
        case .reducing: return "正在重建全文逻辑"
        default: return nil
        }
    }

    var isActive: Bool { self != .ready && self != .error }
}
