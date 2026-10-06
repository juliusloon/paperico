import Foundation

/// 论文库索引的唯一迁移入口。
///
/// **新增字段/ 回填只允许写在这里。** 任何其他位置就地补默认值都会形成第二套迁移写法，
/// 那正是 1.0.x 留下"解码侧兼容、迁移侧空白"的原因。
///
/// 约定：
/// - `current` 只能加一，且必须在 release notes 里说明"旧版本不能再打开新库"的原因；
/// - 每个版本一个 case，从 `from` 逐级升到 `current`，不在一个 case 里跨多版本；
/// - 迁移必须幂等：`migrate(&index, from: current)` 之后再 migrate 结果不变；
/// - 迁移失败抛错，让 `PaperLibrary.load()` 保留原文件，不进入半迁移状态。
enum LibraryIndexMigrations {

    /// 当前索引 schema 版本。
    ///
    /// v2 起因：1.1.0 给 `PaperListItem` 增加 `doi` / `arxiv_id` / `meta_source`。
    /// 之所以必须升版本而不是靠"旧版忽略未知键"——Swift 合成 Codable 会忽略未知键，
    /// 所以 1.0.x **能读** 1.1.0 写出的库；但它写回 `library.json` 时会静默丢掉新字段，
    /// 降级即丢数据。单向升级让用户收到明确的"请升级"提示。
    static let current = 2

    static func migrate(_ index: inout LibraryIndex, from version: Int) throws {
        guard version < current else { return }
        var remaining = version
        while remaining < current {
            switch remaining {
            case 1:
                migrateV1ToV2(&index)
            default:
                throw PipelineError("论文库索引版本 \(remaining) 没有可用的迁移路径，请升级 Paperico。", .storageFailed)
            }
            remaining += 1
        }
        index.schemaVersion = current
    }

    /// v1 → v2：纯增量。`PaperListItem` 的新字段都是 Optional 或带默认值，
    /// 迁移本身无需回填——这里只显式声明版本边界，让新增字段只有一个合法落点。
    private static func migrateV1ToV2(_ index: inout LibraryIndex) {
        for i in index.papers.indices {
            let record = index.papers[i]
            index.papers[i].doi = record.doi
            index.papers[i].arxivId = record.arxivId
            index.papers[i].metaSource = record.metaSource
        }
    }
}