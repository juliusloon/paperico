import Foundation

// MARK: - Data types matching backend schemas
// Decoder uses .convertFromSnakeCase, so Swift names are camelCase mirrors of snake_case fields.

struct ProjectGroup: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String
    var colorTag: String
    var paperCount: Int
    var createdAt: String
}

struct PaperListItem: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var titleZh: String
    var authors: [String]
    var year: Int?
    var domainTags: [String]
    var status: String
    var projectId: String?
    var sourceType: String
    var originalFileName: String
    var createdAt: String
    var lastOpenedAt: String?
    var tldr: String
    var narrativeSummary: String
    var contributions: [String]
    var difficultyEstimate: String
    var venue: String
    var errorMessage: String
    var errorCode: String?
    // Schema v2 (1.1.0). Optional or defaulted so v1 files still decode; any
    // new field must be registered here and in LibraryIndexMigrations, nowhere else.
    var doi: String? = nil
    var arxivId: String? = nil
    /// Provenance of the metadata above: "local" = user's own file, "auto" = looked
    /// up from DOI/arXiv, "manual" = user edited a field; auto never overwrites manual.
    var metaSource: String = MetaSource.local

    var statusEnum: PaperStatus { PaperStatus(raw: status) }
    var displayTitle: String {
        let t = title.isEmpty ? originalFileName : title
        return t.isEmpty ? "未命名论文" : t
    }

    /// Declared explicitly because `init(from:)` below suppresses the memberwise form.
    init(
        id: String, title: String, titleZh: String, authors: [String], year: Int?,
        domainTags: [String], status: String, projectId: String?, sourceType: String,
        originalFileName: String, createdAt: String, lastOpenedAt: String?, tldr: String,
        narrativeSummary: String, contributions: [String], difficultyEstimate: String,
        venue: String, errorMessage: String, errorCode: String?,
        doi: String? = nil, arxivId: String? = nil, metaSource: String = MetaSource.local
    ) {
        self.id = id
        self.title = title
        self.titleZh = titleZh
        self.authors = authors
        self.year = year
        self.domainTags = domainTags
        self.status = status
        self.projectId = projectId
        self.sourceType = sourceType
        self.originalFileName = originalFileName
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.tldr = tldr
        self.narrativeSummary = narrativeSummary
        self.contributions = contributions
        self.difficultyEstimate = difficultyEstimate
        self.venue = venue
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.doi = doi
        self.arxivId = arxivId
        self.metaSource = metaSource
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleZh, authors, year, domainTags, status, projectId
        case sourceType, originalFileName, createdAt, lastOpenedAt, tldr
        case narrativeSummary, contributions, difficultyEstimate, venue
        case errorMessage, errorCode, doi, arxivId, metaSource
    }

    /// Lenient decoding: v1 records simply lack the v2 keys. `decodeIfPresent`
    /// keeps an old library readable without letting a missing field fail the load.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        titleZh = try values.decode(String.self, forKey: .titleZh)
        authors = try values.decodeIfPresent([String].self, forKey: .authors) ?? []
        year = try values.decodeIfPresent(Int.self, forKey: .year)
        domainTags = try values.decodeIfPresent([String].self, forKey: .domainTags) ?? []
        status = try values.decode(String.self, forKey: .status)
        projectId = try values.decodeIfPresent(String.self, forKey: .projectId)
        sourceType = try values.decode(String.self, forKey: .sourceType)
        originalFileName = try values.decodeIfPresent(String.self, forKey: .originalFileName) ?? ""
        createdAt = try values.decode(String.self, forKey: .createdAt)
        lastOpenedAt = try values.decodeIfPresent(String.self, forKey: .lastOpenedAt)
        tldr = try values.decodeIfPresent(String.self, forKey: .tldr) ?? ""
        narrativeSummary = try values.decodeIfPresent(String.self, forKey: .narrativeSummary) ?? ""
        contributions = try values.decodeIfPresent([String].self, forKey: .contributions) ?? []
        difficultyEstimate = try values.decodeIfPresent(String.self, forKey: .difficultyEstimate) ?? ""
        venue = try values.decodeIfPresent(String.self, forKey: .venue) ?? ""
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage) ?? ""
        errorCode = try values.decodeIfPresent(String.self, forKey: .errorCode)
        doi = try values.decodeIfPresent(String.self, forKey: .doi)
        arxivId = try values.decodeIfPresent(String.self, forKey: .arxivId)
        metaSource = try values.decodeIfPresent(String.self, forKey: .metaSource) ?? MetaSource.local
    }
}

/// Allowed values of `PaperListItem.metaSource`. Anything user-edited becomes
/// `manual` and is never overwritten by automatic recognition.
enum MetaSource {
    /// Imported from a local file; no recognized identifier was resolved.
    static let local = "local"
    /// Filled in from Crossref / arXiv by PaperMetadata.
    static let auto = "auto"
    /// At least one metadata field was edited by the user.
    static let manual = "manual"
}

struct Block: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var order: Int
    var kind: String
    var pageIdx: Int?
    /// MinerU page-relative bbox [x0,y0,x1,y1], both axes normalized to 0-1000.
    var bbox: [Double]?
    var sectionTitle: String
    var textOriginal: String
    var textZh: String
    var oneLiner: String
    var keywords: [String]
    var roleInNarrative: String
    var imagePath: String
    var captionOriginal: String
    var captionZh: String
    var figureType: String
    var coreTakeaways: [String]
    var dataReadingNotes: String
    var tableHtml: String
    var latex: String
    var plainExplanation: String
    var entityRefs: [String]
    var headingLevel: Int? = nil
}

struct MethodEntity: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var canonicalKey: String
    var name: String
    var category: String
    var definitionZh: String
    var blockRefs: [String]
}

struct PaperDetail: Codable, Hashable, Sendable {
    var paper: PaperListItem
    var blocks: [Block]
    var entities: [MethodEntity]
}

struct PaperStatusOut: Codable, Hashable, Sendable {
    var id: String
    var status: String
    var errorMessage: String
    var errorCode: String?
}

// MARK: - Chat

enum AttachedContextType: String, Codable, Sendable {
    case textSelection = "text_selection"
    case methodCard = "method_card"
    case figure
    case presetPrompt = "preset_prompt"
    case unknown
    init(raw: String) { self = AttachedContextType(rawValue: raw) ?? .unknown }
}

struct AttachedContext: Codable, Hashable, Sendable {
    var type: String
    var refBlockId: String?
    var refEntityId: String?
    var snippet: String?

    var typeEnum: AttachedContextType { AttachedContextType(raw: type) }

    init(type: String, refBlockId: String? = nil, refEntityId: String? = nil, snippet: String? = nil) {
        self.type = type
        self.refBlockId = refBlockId
        self.refEntityId = refEntityId
        self.snippet = snippet
    }

    private enum Keys: String, CodingKey {
        case type
        case refBlockId = "ref_block_id"
        case refEntityId = "ref_entity_id"
        case snippet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? AttachedContextType.unknown.rawValue
        refBlockId = try? container.decode(String.self, forKey: .refBlockId)
        refEntityId = try? container.decode(String.self, forKey: .refEntityId)
        snippet = try? container.decode(String.self, forKey: .snippet)
    }
}

struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var sessionId: String
    var role: String
    var content: String
    var attachedContext: [AttachedContext]?
    var citedBlockIds: [String]?
    var createdAt: String
    var generationState: String? = nil // stopped | failed; older saved messages decode without this field

}

struct ChatSession: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var paperId: String
    var title: String
    var messages: [ChatMessage]
    var createdAt: String
}

// MARK: - Notes

struct Note: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var paperId: String
    var title: String
    var markdownContent: String
    var createdAt: String
    var updatedAt: String
}

// MARK: - Settings

struct ModelProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var baseUrl: String
    var apiKeyMasked: String
    var apiKeyConfigured: Bool
    var model: String
    var temperature: Double?
    var maxTokens: Int?
    var reasoningEffort: String?
    var streaming: Bool
}

struct ModelProfileCreate: Codable, Hashable, Sendable {
    var id: String?
    var name: String
    var baseUrl: String
    var apiKey: String
    var model: String
    var temperature: Double?
    var maxTokens: Int?
    var reasoningEffort: String?
    var streaming: Bool
}

struct MinerUSettings: Codable, Hashable, Sendable {
    var mode: String
    var baseUrl: String
    var localUrl: String
    var apiKey: String
    var apiKeyConfigured: Bool
    var defaultOptions: MinerUDefaultOptions
}

/// Backend stores this as a free-form dict; paperico always writes these four keys.
/// Decoding is lenient: missing/unknown keys fall back to the documented defaults
/// so a schema drift can never invalidate the whole AppSettings payload.
/// 论文语言交给 MinerU 自动判定,不再作为设置项(旧配置里的 language 键被忽略)。
struct MinerUDefaultOptions: Codable, Hashable, Sendable {
    var isOcr: Bool
    var enableFormula: Bool
    var enableTable: Bool
    var modelBackend: String

    init(isOcr: Bool = false, enableFormula: Bool = true, enableTable: Bool = true, modelBackend: String = "vlm") {
        self.isOcr = isOcr
        self.enableFormula = enableFormula
        self.enableTable = enableTable
        self.modelBackend = modelBackend
    }

    private enum Keys: String, CodingKey {
        case isOcr = "is_ocr"
        case enableFormula = "enable_formula"
        case enableTable = "enable_table"
        case modelBackend = "model_backend"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        isOcr = (try? container.decode(Bool.self, forKey: .isOcr)) ?? false
        enableFormula = (try? container.decode(Bool.self, forKey: .enableFormula)) ?? true
        enableTable = (try? container.decode(Bool.self, forKey: .enableTable)) ?? true
        modelBackend = (try? container.decode(String.self, forKey: .modelBackend)) ?? "vlm"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(isOcr, forKey: .isOcr)
        try container.encode(enableFormula, forKey: .enableFormula)
        try container.encode(enableTable, forKey: .enableTable)
        try container.encode(modelBackend, forKey: .modelBackend)
    }
}

struct AppearanceSettings: Codable, Hashable, Sendable {
    var accentColor: String
    var themeMode: String
    var readingFontSize: Int
    var bilingualLayout: String
}

struct PresetPrompt: Codable, Hashable, Sendable {
    var label: String
    var template: String

    init(label: String, template: String) {
        self.label = label
        self.template = template
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        template = (try? container.decode(String.self, forKey: .template)) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case label, template
    }
}

struct ChatDefaults: Codable, Hashable, Sendable {
    var presetPrompts: [PresetPrompt]
    var targetLanguage: String
    var enableWikilinks: Bool
}

/// 遗留字段：单profile 模式下 5 个 role 恒为 primary，全仓只写不读，暂无消费端。
/// 将来支持按 role 分模型时，在此实现回退链（role → profile → 唯一 profile）。
struct ProfileAssignment: Codable, Hashable, Sendable {
    var translationAndExtraction: String
    var logicChainAndSummary: String
    var figureVision: String
    var chat: String
    var noteSynthesis: String
}

struct AppSettings: Codable, Hashable, Sendable {
    var modelProfiles: [ModelProfile]
    var profileAssignment: ProfileAssignment
    var mineru: MinerUSettings
    var appearance: AppearanceSettings
    var chatDefaults: ChatDefaults
}

struct TestConnectionResult: Codable, Hashable, Sendable {
    var success: Bool
    var message: String
    /// LLM capability probe results; nil for parser tests and legacy responses.
    var supportsReasoning: Bool?
    var reasoningLevels: [String]?
    var defaultMaxOutputTokens: Int?
}

// MARK: - Library

struct MethodIndexPaper: Codable, Hashable, Sendable {
    var paperId: String
    var title: String
    var blockIds: [String]

    init(paperId: String, title: String, blockIds: [String]) {
        self.paperId = paperId
        self.title = title
        self.blockIds = blockIds
    }

    private enum Keys: String, CodingKey {
        case paperId = "paper_id"
        case title
        case blockIds = "block_ids"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        paperId = (try? container.decode(String.self, forKey: .paperId)) ?? ""
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        blockIds = (try? container.decode([String].self, forKey: .blockIds)) ?? []
    }
}

struct MethodIndexItem: Codable, Hashable, Identifiable, Sendable {
    var canonicalKey: String
    var name: String
    var category: String
    var definitionZh: String
    var papers: [MethodIndexPaper]
    var addedAt: String? = nil

    var id: String { canonicalKey }
}
