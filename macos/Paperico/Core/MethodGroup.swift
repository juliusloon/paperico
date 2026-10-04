import Foundation

struct MethodGroup: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String

    static let presets: [MethodGroup] = [
        .init(id: "ML_MODEL", name: "机器学习模型"),
        .init(id: "ALGORITHM", name: "算法/优化方法"),
        .init(id: "INSTRUMENT_METHOD", name: "表征/检测方法"),
        .init(id: "DATASET_BENCHMARK", name: "数据集/基准"),
        .init(id: "METRIC", name: "评价指标"),
        .init(id: "CHEMISTRY", name: "反应类型/试剂"),
        .init(id: "SOFTWARE_TOOL", name: "软件/工具"),
        .init(id: "OTHER", name: "其他")
    ]
}

enum GroupName {
    static func validate(_ value: String, existing: [String]) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PipelineError("分组名称不能为空。", .internalError) }
        guard !existing.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
            throw PipelineError("已存在同名分组，请使用其他名称。", .internalError)
        }
        return name
    }
}
