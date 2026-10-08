import Foundation
import Observation

// MARK: - SettingsStore(原生双 Key 配置)

/// LLM 角色解析占位:当前单配置全角色共用;保留枚举以便未来按角色拆分。
enum LLMRole {
    case translation   // 翻译 + 实体抽取
    case summary       // 逻辑链 + 摘要
    case chat          // 对话
    case notes         // 笔记合成
}

struct LLMProfileConfig: Codable, Hashable, Sendable {
    var id: String = "primary"
    var name: String = ""
    var baseUrl: String = ""
    var model: String = ""
    var temperature: Double = 0.3
    var maxTokens: Int = AnalysisEngine.defaultMaxTokens
    var reasoningEffort: String = "medium"
    var streaming: Bool = true
    var supportsTools: Bool? = nil
}

struct MinerUConfigCore: Codable, Hashable, Sendable {
    var mode: String = "cloud"
    var baseUrl: String = "https://mineru.net/api/v4"
    var localUrl: String = "http://127.0.0.1:7860"
    var defaultOptions: MinerUDefaultOptions = MinerUDefaultOptions()
}

/// 设置真身在本地:LLM 配置与 MinerU 配置存 UserDefaults,两个密钥存 Keychain。
/// `settings` 是为既有视图合成的 AppSettings DTO(掩码密钥 + 默认对话预设)。
@MainActor
@Observable
final class SettingsStore {
    private(set) var llmProfile: LLMProfileConfig
    private(set) var mineruConfig: MinerUConfigCore

    var settings: AppSettings?
    var loading = false
    private var llmCredential = ""
    private var mineruCredential = ""
    private var lockedAccounts: Set<KeychainStore.Account> = []
    private var credentialVersion: UInt = 0
    private var toolProbe: (base: String, model: String, key: String, supported: Bool?)?
    private let credentials: CredentialStore
    private(set) var credentialError = ""
    var credentialsNeedAuthorization: Bool { !lockedAccounts.isEmpty }
    func credentialNeedsAuthorization(_ account: KeychainStore.Account) -> Bool { lockedAccounts.contains(account) }
    private(set) var readingCredentials = false

    /// 外观等合成设置刷新后的回调(AppStore 借此做一次性迁移)。
    var onSettingsApplied: (() -> Void)?

    private let defaults = UserDefaults.standard
    private static let llmKey = "paperico:llm-profile"
    private static let mineruKey = "paperico:mineru-config"

    init(credentials: CredentialStore = .shared) {
        self.credentials = credentials
        llmProfile = Self.loadConfig(LLMProfileConfig.self, key: Self.llmKey, defaults: UserDefaults.standard) ?? LLMProfileConfig()
        mineruConfig = Self.loadConfig(MinerUConfigCore.self, key: Self.mineruKey, defaults: UserDefaults.standard) ?? MinerUConfigCore()
        settings = synthesized
    }

    private static func loadConfig<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(llmProfile) {
            defaults.set(data, forKey: Self.llmKey)
        }
        if let data = try? JSONEncoder().encode(mineruConfig) {
            defaults.set(data, forKey: Self.mineruKey)
        }
    }

    // MARK: - 视图合成

    /// 供既有视图消费的 AppSettings(密钥只出现掩码)。
    var synthesized: AppSettings {
        let key = llmCredential
        let token = mineruCredential
        let profile = ModelProfile(
            id: llmProfile.id,
            name: llmProfile.name.isEmpty ? "主要模型" : llmProfile.name,
            baseUrl: llmProfile.baseUrl,
            apiKeyMasked: Self.maskKey(key),
            apiKeyConfigured: !key.isEmpty,
            model: llmProfile.model,
            temperature: llmProfile.temperature,
            maxTokens: llmProfile.maxTokens,
            reasoningEffort: llmProfile.reasoningEffort,
            streaming: llmProfile.streaming
        )
        return AppSettings(
            modelProfiles: [profile],
            profileAssignment: ProfileAssignment(
                translationAndExtraction: "primary",
                logicChainAndSummary: "primary",
                figureVision: "primary",
                chat: "primary",
                noteSynthesis: "primary"
            ),
            mineru: MinerUSettings(
                mode: mineruConfig.mode,
                baseUrl: mineruConfig.baseUrl,
                localUrl: mineruConfig.localUrl,
                apiKey: Self.maskKey(token),
                apiKeyConfigured: !token.isEmpty,
                defaultOptions: mineruConfig.defaultOptions
            ),
            appearance: AppearanceSettings(
                accentColor: LocalPrefs.accentColor ?? "#2F6FED",
                themeMode: LocalPrefs.themeMode ?? "system",
                readingFontSize: LocalPrefs.readingFontSize ?? 18,
                bilingualLayout: "stacked"
            ),
            chatDefaults: ChatDefaults(
                presetPrompts: Self.defaultPresetPrompts,
                targetLanguage: "zh-CN",
                enableWikilinks: true
            )
        )
    }

    static let defaultPresetPrompts: [PresetPrompt] = [
        PresetPrompt(label: "总结全文", template: "请用200-300字总结这篇论文的核心内容，包括问题、方法、结果和结论。"),
        PresetPrompt(label: "总结方法", template: "请详细总结本文使用的核心方法/技术手段及其创新点。"),
        PresetPrompt(label: "亮点与创新点", template: "请列出本文的主要创新点和亮点贡献。"),
        PresetPrompt(label: "局限与未来方向", template: "请分析本文的局限性以及可能的未来研究方向。"),
        PresetPrompt(label: "提取实验设置", template: "请提取本文的实验设置，包括数据集、评价指标、基线方法和关键超参数。"),
        PresetPrompt(label: "生成自测思考题", template: "请基于本文内容生成5道思考题，帮助我检验对论文的理解程度。"),
    ]

    static func maskKey(_ key: String) -> String {
        guard key.count >= 8 else { return key.isEmpty ? "" : "****" }
        return key.prefix(4) + "****" + key.suffix(4)
    }

    // MARK: - 读写

    func fetch() async {
        loading = true
        defer { loading = false }
        llmProfile = Self.loadConfig(LLMProfileConfig.self, key: Self.llmKey, defaults: defaults) ?? llmProfile
        mineruConfig = Self.loadConfig(MinerUConfigCore.self, key: Self.mineruKey, defaults: defaults) ?? mineruConfig
        await readSavedCredentials()
    }

    func readSavedCredentials(allowInteraction: Bool = false) async {
        guard !readingCredentials else { return }
        readingCredentials = true
        let version = credentialVersion
        defer { readingCredentials = false }
        let snapshot = await credentials.readAll(allowInteraction: allowInteraction)
        guard version == credentialVersion else { return }
        let llm = snapshot[.llmApiKey]
        let mineru = snapshot[.mineruToken]
        if !llm.needsAuthorization { llmCredential = llm.value }
        if !mineru.needsAuthorization { mineruCredential = mineru.value }
        credentialError = snapshot.error
        lockedAccounts = Set(KeychainStore.Account.allCases.filter { snapshot[$0].needsAuthorization })
        settings = synthesized
        onSettingsApplied?()
    }

    /// 保存唯一 LLM 配置并分配给所有角色;Key 非空时写入 Keychain。
    func saveLLMProfile(profile: ModelProfileCreate) async throws {
        _ = try ServiceURL.endpoint(base: LLMClient.normalizeBaseURL(profile.baseUrl), path: "/chat/completions")
        guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineError("请填写模型名称", .llmNotConfigured)
        }
        if !profile.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            let key = profile.apiKey.trimmingCharacters(in: .whitespaces)
            try await credentials.write(key, to: .llmApiKey)
            llmCredential = key
            credentialVersion &+= 1
            lockedAccounts.remove(.llmApiKey)
        }
        let base = LLMClient.normalizeBaseURL(profile.baseUrl)
        let probed = toolProbe.flatMap { $0.base == base && $0.model == profile.model && $0.key == llmCredential ? $0.supported : nil }
        let previous = LLMClient.normalizeBaseURL(llmProfile.baseUrl) == base && llmProfile.model == profile.model && profile.apiKey.isEmpty ? llmProfile.supportsTools : nil
        llmProfile = LLMProfileConfig(
            id: profile.id ?? "primary",
            name: profile.name,
            baseUrl: profile.baseUrl,
            model: profile.model,
            temperature: profile.temperature ?? 0.3,
            maxTokens: profile.maxTokens ?? AnalysisEngine.defaultMaxTokens,
            reasoningEffort: profile.reasoningEffort ?? "medium",
            streaming: profile.streaming,
            supportsTools: probed ?? previous
        )
        persist()
        settings = synthesized
        onSettingsApplied?()
    }

    /// 保存 MinerU 配置;Token 非空时写入 Keychain。
    func saveMinerU(_ mineru: MinerUSettings) async throws {
        _ = try ServiceURL.endpoint(base: mineru.mode == "local" ? mineru.localUrl : mineru.baseUrl, path: "")
        if !mineru.apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
            let token = mineru.apiKey.trimmingCharacters(in: .whitespaces)
            try await credentials.write(token, to: .mineruToken)
            mineruCredential = token
            credentialVersion &+= 1
            lockedAccounts.remove(.mineruToken)
        }
        mineruConfig = MinerUConfigCore(
            mode: mineru.mode,
            baseUrl: mineru.baseUrl,
            localUrl: mineru.localUrl,
            defaultOptions: mineru.defaultOptions
        )
        persist()
        settings = synthesized
        onSettingsApplied?()
    }

    // MARK: - 管线取用

    /// 遗留签名：`role` 目前被忽略，任何 role 都返回同一个 `llmProfile`。
    /// 保留参数是为了调用点能表达意图（翻译 / 对话 / 笔记合成），
    /// 将来支持按 role 分模型时在此实现回退链，而不是让 role 悄悄失效。
    func llmConfig(for role: LLMRole) -> AnalysisEngine.LLMConfig {
        AnalysisEngine.LLMConfig(
            baseURL: LLMClient.normalizeBaseURL(llmProfile.baseUrl),
            apiKey: llmCredential,
            model: llmProfile.model,
            reasoningEffort: llmProfile.reasoningEffort,
            temperature: llmProfile.temperature,
            maxTokens: llmProfile.maxTokens,
            streaming: llmProfile.streaming,
            supportsTools: llmProfile.supportsTools
        )
    }

    func invalidateTools(for config: AnalysisEngine.LLMConfig) {
        guard config.baseURL == LLMClient.normalizeBaseURL(llmProfile.baseUrl), config.model == llmProfile.model, config.apiKey == llmCredential else { return }
        llmProfile.supportsTools = nil; toolProbe = nil; persist()
    }

    func mineruClientConfig() -> MinerUClient.Config {
        MinerUClient.Config(
            mode: mineruConfig.mode,
            baseUrl: mineruConfig.baseUrl,
            localUrl: mineruConfig.localUrl,
            token: mineruCredential,
            options: mineruConfig.defaultOptions
        )
    }

    // MARK: - 连通性探测(原 /api/settings/test-* 的原生等价)

    func testLLM(baseUrl: String, apiKey: String, model: String) async -> TestConnectionResult {
        let result = await LLMProbe.testLLM(
            baseURL: baseUrl, apiKey: apiKey, model: model,
            savedKey: llmCredential
        )
        if result.success {
            let base = LLMClient.normalizeBaseURL(baseUrl)
            let key = apiKey.isEmpty ? llmCredential : apiKey
            toolProbe = (base, model, key, result.supportsTools)
            if base == LLMClient.normalizeBaseURL(llmProfile.baseUrl), model == llmProfile.model, key == llmCredential {
                llmProfile.supportsTools = result.supportsTools; persist()
            }
        }
        return TestConnectionResult(
            success: result.success,
            message: result.message,
            supportsReasoning: result.supportsReasoning,
            reasoningLevels: result.reasoningLevels,
            defaultMaxOutputTokens: result.defaultMaxOutputTokens,
            supportsTools: result.supportsTools
        )
    }

    func testMinerU(mode: String, baseUrl: String, localUrl: String, apiKey: String) async -> TestConnectionResult {
        let config = MinerUClient.Config(
            mode: mode,
            baseUrl: baseUrl,
            localUrl: localUrl,
            token: apiKey,
            options: mineruConfig.defaultOptions
        )
        let result = await MinerUClient.testMinerU(config: config, savedToken: mineruCredential)
        return TestConnectionResult(success: result.success, message: result.message)
    }
}
