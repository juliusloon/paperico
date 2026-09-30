import SwiftUI

/// Mirrors settings/SettingsPage.tsx — three tabs (AI 模型 / PDF 解析 / 阅读外观),
/// readiness card, test-connection actions, bottom notice.
/// 窄窗口(≤800px,与 web 断点一致)切换为单栏 + 横向 tab。
struct SettingsPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(AppStore.self) private var appStore

    @State private var tab: Tab = .model
    @State private var saving = false
    @State private var testingLlm = false
    @State private var testingMineru = false
    @State private var notice: Notice?
    @State private var showLlmKey = false
    @State private var showMineruKey = false
    @State private var showAccentPicker = false

    // LLM form (mirrors llmForm)
    @State private var llmId = "primary"
    @State private var llmName = "主要模型"
    @State private var llmBaseUrl = "https://api.openai.com/v1"
    @State private var llmApiKey = ""
    @State private var llmModel = "gpt-4o-mini"
    @State private var llmMaxTokens = 8192
    @State private var llmReasoning = "medium"

    // MinerU form (mirrors mineruForm)
    @State private var mineruMode = "cloud"
    @State private var mineruBaseUrl = "https://mineru.net/api/v4"
    @State private var mineruLocalUrl = "http://127.0.0.1:7860"
    @State private var mineruApiKey = ""
    @State private var mineruIsOcr = false
    @State private var mineruEnableFormula = true
    @State private var mineruEnableTable = true
    @State private var mineruLanguage = "en"
    @State private var mineruModelBackend = "vlm"

    // Appearance form
    @State private var appearanceAccent = "#275DCE"
    @State private var appearanceTheme = "system"
    @State private var appearanceFontSize = 18

    enum Tab: String, CaseIterable {
        case model, parser, appearance
        var label: String {
            switch self {
            case .model: return "AI 模型"
            case .parser: return "PDF 解析"
            case .appearance: return "阅读外观"
            }
        }
        var description: String {
            switch self {
            case .model: return "翻译、总结与问答"
            case .parser: return "MinerU 云端或本地部署"
            case .appearance: return "主题、强调色与字号"
            }
        }
        var icon: String {
            switch self {
            case .model: return Ic.bolt
            case .parser: return Ic.server
            case .appearance: return Ic.palette
            }
        }
    }

    struct Notice: Equatable {
        let success: Bool
        let message: String
    }

    private var isCompact: Bool { containerWidth < LayoutBreakpoint.settings }

    private var llmReady: Bool {
        settingsStore.settings?.modelProfiles.first?.apiKeyConfigured ?? false
    }

    private var mineruReady: Bool {
        if mineruMode == "local" { return !mineruLocalUrl.trimmingCharacters(in: .whitespaces).isEmpty }
        return settingsStore.settings?.mineru.apiKeyConfigured ?? false
    }

    private var readyCount: Int { (llmReady ? 1 : 0) + (mineruReady ? 1 : 0) }

    var body: some View {
        Group {
            if isCompact {
                VStack(spacing: 0) {
                    CompactTopBar()
                    ScrollView {
                        VStack(spacing: 12) {
                            compactTabBar
                            sectionCard
                        }
                        .padding(8)
                    }
                }
                .background(palette.gray0)
            } else {
                // 左列:设置侧栏在上,导航栏贴底收尾
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        sidebarCard
                            .frame(maxHeight: .infinity, alignment: .top)
                        WorkspaceNav(opensUpward: true)
                    }
                    .frame(width: 224)
                    .zIndex(1)
                    sectionCard
                }
                .padding(14)
                .background(palette.gray0)
            }
        }
        .task { hydrateFromSettings() }
        .overlay(alignment: .bottomTrailing) { noticeOverlay }
    }

    /// 紧凑宽度:三个设置 tab 变成横向分段条(web ≤800px)。
    private var compactTabBar: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 6) {
                        Image.ic(item.icon).font(.system(size: 13))
                        Text(item.label).font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(tab == item ? .white : palette.gray500)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 9).fill(tab == item ? palette.accent : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noFocusRing()
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.gray50))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.gray200))
    }

    // MARK: sidebar

    private var sidebarCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 7) {
                        Image.ic(item.icon)
                            .font(.system(size: 14))
                            .frame(width: 22)
                            .foregroundStyle(tab == item ? palette.accent : palette.gray500)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label).font(.system(size: 15, weight: tab == item ? .semibold : .regular))
                                .foregroundStyle(tab == item ? palette.accent : palette.gray500)
                            if !isCompact {
                                Text(item.description).font(.system(size: 12)).foregroundStyle(palette.gray400)
                            }
                        }
                        Spacer(minLength: 0)
                        if !isCompact {
                            Image.ic(Ic.chevronRight).font(.system(size: 12)).foregroundStyle(palette.gray400)
                        }
                    }
                    .padding(9)
                    .frame(minHeight: 54)
                    .background(RoundedRectangle(cornerRadius: 9).fill(tab == item ? palette.accentSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .noFocusRing()
            }

            Spacer(minLength: 0)

            HStack(spacing: 9) {
                Image.ic(Ic.shieldAlert).font(.system(size: 16)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("流程就绪度 \(readyCount)/2").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.gray700)
                    Text(readyCount == 2 ? "可以上传并处理论文" : "需要补齐下方连接").font(.system(size: 12)).foregroundStyle(palette.gray500)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(palette.accentFaint))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray200))
        }
        .padding(18)
        .trafficLightTopPadding()
        .liquidPanel(cornerRadius: 14)
    }

    // MARK: content

    private var sectionCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader
                Group {
                    switch tab {
                    case .model: modelSection
                    case .parser: parserSection
                    case .appearance: appearanceSection
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .trafficLightTopPadding()
        .liquidPanel(cornerRadius: 14)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var sectionHeader: some View {
        let (kicker, title, description, configured): (String, String, String, Bool) = {
            switch tab {
            case .model:
                return ("MODEL CONNECTION", "AI 模型连接",
                        "使用 OpenAI-compatible Chat Completions 接口。配置仅保存在本机数据库中,并使用稳定的本机密钥加密;一个配置会自动用于翻译、逻辑归纳、Chatbot 和笔记生成。", llmReady)
            case .parser:
                let local = mineruMode == "local"
                return ("DOCUMENT PARSER", "MinerU 精准解析",
                        local ? "调用本机部署的 MinerU Gradio 服务(如 Docker 版 mineru-gradio),无需 Token;MinerU.Chem 化学解析目前仅云端提供。"
                              : "MinerU Token 仅保存在本机数据库中,并使用稳定的本机密钥加密。本地 PDF 会申请官方签名上传地址,上传后自动轮询批任务。",
                        mineruReady)
            case .appearance:
                return ("READING APPEARANCE", "阅读外观", "这些设置只影响界面,不会改变论文数据。", true)
            }
        }()

        HStack(alignment: .top, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                Text(kicker).font(.mono(10, weight: .bold)).kerning(1.6).foregroundStyle(palette.accent)
                Text(title).font(.reading(30, weight: .medium)).foregroundStyle(palette.gray900).padding(.vertical, 4)
                Text(description).font(.system(size: 14.5)).lineSpacing(6).foregroundStyle(palette.gray500)
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image.ic(configured ? Ic.check : Ic.close).font(.system(size: 10))
                Text(configured ? "已配置" : "需要配置")
            }
            .font(.system(size: 12))
            .foregroundStyle(configured ? palette.success : palette.danger)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(configured ? palette.success.opacity(0.1) : palette.danger.opacity(0.09)))
        }
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }
        .padding(.bottom, 31)
    }

    /// 字段行:名称与控件同一行,提示文字由控件的 placeholder 承载。
    private func field<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(palette.gray700)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 88, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 两列并排的字段(窄屏收为单列)。
    private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Group {
            if isCompact {
                VStack(alignment: .leading, spacing: 14) { content() }
            } else {
                HStack(alignment: .center, spacing: 18) { content() }
            }
        }
    }

    private func textFieldBinding(_ text: Binding<String>, placeholder: String) -> some View {
        FormTextField(text: text, placeholder: placeholder)
    }

    private func pickerBinding(_ value: Binding<String>, options: [(String, String)]) -> some View {
        PillPicker(selection: value, options: options)
    }

    private func secretField(_ text: Binding<String>, placeholder: String, visible: Binding<Bool>) -> some View {
        FormSecretField(text: text, placeholder: placeholder, visible: visible)
    }

    // MARK: model tab

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            fieldRow {
                field("配置名称") {
                    textFieldBinding($llmName, placeholder: "主要模型")
                }
                field("模型名称") {
                    textFieldBinding($llmModel, placeholder: "必须与服务商控制台中的 model id 完全一致")
                }
            }
            field("Base URL") {
                textFieldBinding($llmBaseUrl, placeholder: "填写到 /v1,应用会自动追加 /chat/completions")
            }
            field("API Key") {
                secretField(
                    $llmApiKey,
                    placeholder: llmReady
                        ? "已保存:\(settingsStore.settings?.modelProfiles.first?.apiKeyMasked ?? "")。留空会继续使用,不会覆盖。"
                        : "测试时会先安全保存当前配置。",
                    visible: $showLlmKey
                )
            }
            fieldRow {
                field("思考强度") {
                    pickerBinding($llmReasoning, options: [("off", "关闭"), ("low", "低"), ("medium", "中"), ("high", "高")])
                }
                field("单次最大输出") {
                    FormStepper(title: "\(llmMaxTokens)", value: $llmMaxTokens, range: 256...32768, step: 256)
                }
            }
            actionRow(testing: $testingLlm, saveTitle: "保存配置", testTitle: "保存并测试") {
                saveLLM()
            } onTest: {
                testLLM()
            }
        }
    }

    // MARK: parser tab

    private var parserSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            field("解析方式") {
                pickerBinding($mineruMode, options: [("cloud", "MinerU 云端 API"), ("local", "本地部署(Gradio 服务)")])
            }
            if mineruMode == "local" {
                field("本地服务地址") {
                    textFieldBinding($mineruLocalUrl, placeholder: "指向 mineru-gradio 的 HTTP 地址,例如 http://127.0.0.1:7860")
                }
            } else {
                field("Base URL") {
                    textFieldBinding($mineruBaseUrl, placeholder: "https://mineru.net/api/v4")
                }
                field("MinerU Token") {
                    secretField(
                        $mineruApiKey,
                        placeholder: settingsStore.settings?.mineru.apiKeyConfigured == true
                            ? "已保存。留空保存不会覆盖。"
                            : "在 MinerU API 管理页面创建 Token(只填写 Token 本身)",
                        visible: $showMineruKey
                    )
                }
            }
            fieldRow {
                field("解析模型") {
                    if mineruMode == "local" {
                        pickerBinding($mineruModelBackend, options: [("pipeline", "Pipeline"), ("vlm", "VLM Engine"), ("hybrid-engine", "Hybrid Engine")])
                    } else {
                        pickerBinding($mineruModelBackend, options: [("vlm", "VLM(推荐)"), ("pipeline", "Pipeline")])
                    }
                }
                field("论文语言") {
                    pickerBinding($mineruLanguage, options: [("en", "英文"), ("ch", "中文"), ("japan", "日文"), ("korean", "韩文")])
                }
            }

            HStack(spacing: 22) {
                Toggle("公式识别", isOn: $mineruEnableFormula).toggleStyle(.switch).font(.system(size: 13))
                Toggle("表格识别", isOn: $mineruEnableTable).toggleStyle(.switch).font(.system(size: 13))
                Toggle("强制 OCR", isOn: $mineruIsOcr).toggleStyle(.switch).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 9).fill(palette.gray0))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.gray200))

            Text("你的示例是可检索文字型 PDF,建议关闭“强制 OCR”;公式和表格识别保持开启。")
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(palette.gray500)
                .padding(.leading, 13)
                .overlay(alignment: .leading) { Rectangle().fill(palette.accent).frame(width: 2) }
                .padding(.vertical, 11)

            actionRow(testing: $testingMineru, saveTitle: "保存配置", testTitle: "测试连接") {
                saveMinerU()
            } onTest: {
                testMinerU()
            }
        }
    }

    // MARK: appearance tab

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            fieldRow {
                field("主题") {
                    pickerBinding($appearanceTheme, options: [("light", "亮色"), ("dark", "暗色"), ("system", "跟随系统")])
                }
                field("正文字号") {
                    FormStepper(title: "\(appearanceFontSize)", value: $appearanceFontSize, range: 13...23)
                }
            }
            field("强调色") {
                HStack(spacing: 9) {
                    accentSwatch
                    textFieldBinding($appearanceAccent, placeholder: "#275DCE")
                }
            }
            actionRow(testing: .constant(false), saveTitle: "保存配置", testTitle: nil) {
                saveAppearance()
            } onTest: {}
        }
    }

    /// 强调色示例块:与字段框同规格的圆角矩形,点按弹出预设色板 + 系统拾色器。
    private var accentSwatch: some View {
        Button {
            showAccentPicker = true
        } label: {
            RoundedRectangle(cornerRadius: ControlSpec.radius)
                .fill(Color(hex: appearanceAccent) ?? palette.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: ControlSpec.radius)
                        .strokeBorder(palette.gray300, lineWidth: 1)
                        .opacity(0.6)
                )
                .overlay(alignment: .center) {
                    Image.ic(Ic.penLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .frame(width: 44, height: ControlSpec.height)
        }
        .buttonStyle(.plain)
        .noFocusRing()
        .help("选取强调色")
        .popover(isPresented: $showAccentPicker, arrowEdge: .bottom) {
            accentPickerPopover
                .presentationCompactAdaptation(.popover)
        }
    }

    private var accentPickerPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预设强调色")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.gray700)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 8), count: 6), spacing: 10) {
                ForEach(accentPresets, id: \.self) { hex in
                    Button {
                        appearanceAccent = hex
                    } label: {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(hex: hex) ?? palette.accent)
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(appearanceAccent.caseInsensitiveCompare(hex) == .orderedSame ? palette.gray800 : palette.gray300, lineWidth: appearanceAccent.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 1)
                                    .opacity(0.8)
                            )
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .noFocusRing()
                    .help(hex)
                }
            }
            Divider()
            HStack(spacing: 9) {
                ColorPicker("", selection: Binding(
                    get: { Color(hex: appearanceAccent) ?? palette.accent },
                    set: { newValue in
                        if let hex = newValue.toHex() { appearanceAccent = hex }
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                Text("自定义颜色")
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.gray600)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private var accentPresets: [String] {
        ["#275DCE", "#2F6FED", "#0E7C66", "#0891B2", "#4F46E5", "#7C3AED",
         "#B66A12", "#D97706", "#B64235", "#DB2777", "#237A52", "#515762"]
    }

    // MARK: shared actions row

    private func actionRow(testing: Binding<Bool>, saveTitle: String, testTitle: String?, onSave: @escaping () -> Void, onTest: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            ToolbarButton(title: saveTitle, icon: Ic.save, kind: .primary, busy: saving || testing.wrappedValue) {
                onSave()
            }

            if let testTitle {
                ToolbarButton(title: testTitle, icon: Ic.testTube, busy: testing.wrappedValue) {
                    onTest()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 22)
        .overlay(alignment: .top) { Rectangle().fill(palette.gray200).frame(height: 1) }
    }

    // MARK: actions

    private func hydrateFromSettings() {
        guard let settings = settingsStore.settings else { return }
        appearanceAccent = settings.appearance.accentColor
        appearanceTheme = settings.appearance.themeMode
        appearanceFontSize = settings.appearance.readingFontSize

        let mineru = settings.mineru
        mineruMode = mineru.mode
        mineruBaseUrl = mineru.baseUrl
        mineruLocalUrl = mineru.localUrl.isEmpty ? "http://127.0.0.1:7860" : mineru.localUrl
        let options = mineru.defaultOptions
        mineruIsOcr = options.isOcr
        mineruEnableFormula = options.enableFormula
        mineruEnableTable = options.enableTable
        mineruLanguage = options.language
        mineruModelBackend = options.modelBackend

        if let profile = settings.modelProfiles.first {
            llmId = profile.id
            llmName = profile.name
            llmBaseUrl = profile.baseUrl
            llmModel = profile.model
            llmMaxTokens = profile.maxTokens ?? 8192
            llmReasoning = profile.reasoningEffort ?? "medium"
        }
    }

    private func normalizedProfile() -> ModelProfileCreate {
        var base = llmBaseUrl.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { base = String(base.dropLast("/chat/completions".count)) }
        return ModelProfileCreate(
            id: llmId.isEmpty ? "primary" : llmId,
            name: llmName.trimmingCharacters(in: .whitespaces).isEmpty ? "主要模型" : llmName.trimmingCharacters(in: .whitespaces),
            baseUrl: base,
            apiKey: llmApiKey.trimmingCharacters(in: .whitespaces),
            model: llmModel.trimmingCharacters(in: .whitespaces),
            temperature: 0.3,
            maxTokens: llmMaxTokens,
            reasoningEffort: llmReasoning,
            streaming: true
        )
    }

    private func saveLLM() {
        runAction {
            let profile = normalizedProfile()
            try await settingsStore.saveLLMProfile(profile: profile)
            llmApiKey = ""
            notice = Notice(success: true, message: "模型配置已保存,并已分配给解析、总结、对话和笔记流程。")
            hydrateFromSettings()
        }
    }

    private func saveMinerU() {
        runAction {
            let mineru = MinerUSettings(
                mode: mineruMode,
                baseUrl: mineruBaseUrl.trimmingCharacters(in: .whitespaces),
                localUrl: mineruLocalUrl.trimmingCharacters(in: .whitespaces),
                apiKey: mineruApiKey.trimmingCharacters(in: .whitespaces),
                apiKeyConfigured: settingsStore.settings?.mineru.apiKeyConfigured ?? false,
                defaultOptions: MinerUDefaultOptions(
                    isOcr: mineruIsOcr,
                    enableFormula: mineruEnableFormula,
                    enableTable: mineruEnableTable,
                    language: mineruLanguage,
                    modelBackend: mineruModelBackend
                )
            )
            try await settingsStore.saveMinerU(mineru)
            mineruApiKey = ""
            notice = Notice(success: true, message: "MinerU 配置已保存。")
        }
    }

    private func saveAppearance() {
        runAction {
            let appearance = AppearanceSettings(
                accentColor: appearanceAccent,
                themeMode: appearanceTheme,
                readingFontSize: appearanceFontSize,
                bilingualLayout: "stacked"
            )
            try await settingsStore.saveAppearance(appearance)
            appStore.setAccent(appearanceAccent)
            appStore.setTheme(appearanceTheme)
            notice = Notice(success: true, message: "阅读外观已保存。")
        }
    }

    private func testLLM() {
        notice = nil
        testingLlm = true
        Task {
            defer { testingLlm = false }
            let profile = normalizedProfile()
            if profile.apiKey.isEmpty && !llmReady {
                notice = Notice(success: false, message: "请先填写 API Key,再保存并测试。")
                return
            }
            do {
                try await settingsStore.saveLLMProfile(profile: profile)
                llmApiKey = ""
                let result = try await ApiClient().settingsTestLLM(baseUrl: profile.baseUrl, apiKey: "", model: profile.model, profileId: profile.id ?? "primary")
                notice = Notice(success: result.success, message: result.message)
                hydrateFromSettings()
            } catch {
                notice = Notice(success: false, message: ApiFailure.wrap(error).errorDescription ?? "操作失败,请检查配置后重试。")
            }
        }
    }

    private func testMinerU() {
        notice = nil
        testingMineru = true
        Task {
            defer { testingMineru = false }
            do {
                let result = try await ApiClient().settingsTestMinerU(
                    mode: mineruMode,
                    baseUrl: mineruBaseUrl.trimmingCharacters(in: .whitespaces),
                    localUrl: mineruLocalUrl.trimmingCharacters(in: .whitespaces),
                    apiKey: mineruApiKey.trimmingCharacters(in: .whitespaces)
                )
                notice = Notice(success: result.success, message: result.message)
            } catch {
                notice = Notice(success: false, message: ApiFailure.wrap(error).errorDescription ?? "操作失败,请检查配置后重试。")
            }
        }
    }

    private func runAction(_ action: @escaping () async throws -> Void) {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await action()
            } catch {
                notice = Notice(success: false, message: ApiFailure.wrap(error).errorDescription ?? "操作失败,请检查配置后重试。")
            }
        }
    }

    // MARK: notice overlay (bottom-right card)

    private var noticeOverlay: some View {
        Group {
            if let notice {
                HStack(spacing: 8) {
                    Image.ic(notice.success ? Ic.check : Ic.close).font(.system(size: 13))
                    Text(notice.message).font(.system(size: 12)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.notice = nil
                    } label: {
                        Image.ic(Ic.close).font(.system(size: 10)).foregroundStyle(palette.gray500)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(notice.success ? palette.success : palette.danger)
                .padding(13)
                .frame(width: 420)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill((notice.success ? palette.success : palette.danger).opacity(0.08))
                        .background(palette.gray0, in: RoundedRectangle(cornerRadius: 9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke((notice.success ? palette.success : palette.danger).opacity(0.3))
                )
                .shadow(color: palette.shadowCard, radius: 10, y: 4)
                .padding(20)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notice)
    }
}

// MARK: - Password/plain toggle field

struct SecureOrPlainField: View {
    let text: Binding<String>
    let visible: Bool
    let placeholder: String

    var body: some View {
        Group {
            if visible {
                TextField(placeholder, text: text)
            } else {
                SecureField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }
}

// MARK: - Color hex helper

extension Color {
    func toHex() -> String? {
        guard let components = rgbComponents, components.count >= 3 else { return nil }
        let r = Int(round(components[0] * 255))
        let g = Int(round(components[1] * 255))
        let b = Int(round(components[2] * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
