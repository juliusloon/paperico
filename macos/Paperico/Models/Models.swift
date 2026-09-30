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

    var statusEnum: PaperStatus { PaperStatus(raw: status) }
    var displayTitle: String {
        let t = title.isEmpty ? originalFileName : title
        return t.isEmpty ? "未命名论文" : t
    }
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

/// Backend stores this as a free-form dict; paperico always writes these five keys.
/// Decoding is lenient: missing/unknown keys fall back to the documented defaults
/// so a schema drift can never invalidate the whole AppSettings payload.
struct MinerUDefaultOptions: Codable, Hashable, Sendable {
    var isOcr: Bool
    var enableFormula: Bool
    var enableTable: Bool
    var language: String
    var modelBackend: String

    init(isOcr: Bool = false, enableFormula: Bool = true, enableTable: Bool = true, language: String = "en", modelBackend: String = "vlm") {
        self.isOcr = isOcr
        self.enableFormula = enableFormula
        self.enableTable = enableTable
        self.language = language
        self.modelBackend = modelBackend
    }

    private enum Keys: String, CodingKey {
        case isOcr = "is_ocr"
        case enableFormula = "enable_formula"
        case enableTable = "enable_table"
        case language
        case modelBackend = "model_backend"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        isOcr = (try? container.decode(Bool.self, forKey: .isOcr)) ?? false
        enableFormula = (try? container.decode(Bool.self, forKey: .enableFormula)) ?? true
        enableTable = (try? container.decode(Bool.self, forKey: .enableTable)) ?? true
        language = (try? container.decode(String.self, forKey: .language)) ?? "en"
        modelBackend = (try? container.decode(String.self, forKey: .modelBackend)) ?? "vlm"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(isOcr, forKey: .isOcr)
        try container.encode(enableFormula, forKey: .enableFormula)
        try container.encode(enableTable, forKey: .enableTable)
        try container.encode(language, forKey: .language)
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

    var id: String { canonicalKey }
}
