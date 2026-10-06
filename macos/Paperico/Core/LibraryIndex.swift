import Foundation

struct MethodIndexContent: Codable, Equatable, Sendable {
    var name: String
    var category: String
    var definitionZh: String
}

struct TrashedPaper: Codable, Identifiable, Sendable {
    var paper: PaperListItem
    var deletedAt: String
    var id: String { paper.id }
}

/// Version 1 also accepts the unversioned index used during the native migration.
/// Newer schema versions are migrated through `LibraryIndexMigrations` — the only
/// place where a version boundary may add or backfill fields.
struct LibraryIndex: Codable {
    var schemaVersion = LibraryIndexMigrations.current
    var projects: [ProjectGroup] = []
    var papers: [PaperListItem] = []
    var shaByPaperId: [String: String] = [:]
    var sourceUrlByPaperId: [String: String] = [:]
    var trash: [TrashedPaper] = []
    var methodContent: [String: MethodIndexContent] = [:]
    var methodAliases: [String: String] = [:]
    var hiddenMethods: [String] = []
    var methodAddedAt: [String: String] = [:]
    var methodGroups: [MethodGroup] = MethodGroup.presets

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, papers, shaByPaperId, sourceUrlByPaperId, trash
        case methodContent, methodAliases, hiddenMethods, methodAddedAt, methodGroups
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // The unversioned index written during the Web → native migration counts as v1.
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= LibraryIndexMigrations.current else {
            throw PipelineError("论文库由更新版本创建，请升级 Paperico 后再打开。", .storageFailed)
        }
        // These existed before versioning; missing required fields indicate corruption.
        projects = try values.decode([ProjectGroup].self, forKey: .projects)
        papers = try values.decode([PaperListItem].self, forKey: .papers)
        shaByPaperId = try values.decodeIfPresent([String: String].self, forKey: .shaByPaperId) ?? [:]
        sourceUrlByPaperId = try values.decodeIfPresent([String: String].self, forKey: .sourceUrlByPaperId) ?? [:]
        trash = try values.decodeIfPresent([TrashedPaper].self, forKey: .trash) ?? []
        methodContent = try values.decodeIfPresent([String: MethodIndexContent].self, forKey: .methodContent) ?? [:]
        methodAliases = try values.decodeIfPresent([String: String].self, forKey: .methodAliases) ?? [:]
        hiddenMethods = try values.decodeIfPresent([String].self, forKey: .hiddenMethods) ?? []
        methodAddedAt = try values.decodeIfPresent([String: String].self, forKey: .methodAddedAt) ?? [:]
        methodGroups = try values.decodeIfPresent([MethodGroup].self, forKey: .methodGroups) ?? MethodGroup.presets
        schemaVersion = version
        try LibraryIndexMigrations.migrate(&self, from: version)
    }
}
