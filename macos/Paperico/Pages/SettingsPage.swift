import SwiftUI

/// Native settings: AI 模型 / PDF 解析 / 阅读外观 / MCP 连接,
/// readiness card, test-connection actions, bottom notice.
/// 窄窗口保留桌面布局,侧栏收成三个圆形图标。
struct SettingsPage: View {
    @Environment(\.palette) private var palette
    @Environment(\.containerWidth) private var containerWidth
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(AppStore.self) private var appStore
    @Environment(MCPStore.self) private var mcpStore
    @Environment(UpdateStore.self) private var updateStore
    @Environment(\.openURL) private var openURL

    @AppStorage("paperico:allow-library-chat") private var allowLibraryChat = false
    @State private var tab: Tab = .model
    @State private var saving = false
    @State private var testingLlm = false
    @State private var testingMineru = false
    @State private var notice: Notice?
    @State private var showLlmKey = false
    @State private var showMineruKey = false
    @State private var showMCPToken = false
    @State private var showAccentPicker = false

    // LLM form (mirrors llmForm) — 连接三项默认留空,由 placeholder 承载提示;
    // 思考强度/单次最大输出在「测试连通性」成功后才解锁选择。
    @State private var llmId = "primary"
    @State private var llmName = ""
    @State private var llmBaseUrl = ""
    @State private var llmApiKey = ""
    @State private var llmModel = ""
    @State private var llmMaxTokens = AnalysisEngine.defaultMaxTokens
    @State private var llmReasoning = "medium"
    @State private var llmCaps: LLMCaps?
    @State private var llmTestedKey: String?

    /// 测试连通性后拿到的模型能力(思考强度档位与默认单次最大输出)。
    private struct LLMCaps: Equatable {
        let levels: [String]
        let maxOutputDefault: Int?
    }

    // MinerU form (mirrors mineruForm)
    @State private var mineruMode = "cloud"
    @State private var mineruBaseUrl = "https://mineru.net/api/v4"
    @State private var mineruLocalUrl = "http://127.0.0.1:7860"
    @State private var mineruApiKey = ""
    @State private var mineruIsOcr = false
    @State private var mineruEnableFormula = true
    @State private var mineruEnableTable = true
    @State private var mineruModelBackend = "vlm"

    // Appearance form
    @State private var appearanceAccent = "#275DCE"
    @State private var appearanceTheme = "system"
    @State private var appearanceFontSize = 18

    enum Tab: String, CaseIterable {
        case model, parser, appearance, automation, about
        var label: String {
            switch self {
            case .model: return "AI 模型"
            case .parser: return "PDF 解析"
            case .appearance: return "阅读外观"
            case .automation: return "MCP 连接"
            case .about: return "关于"
            }
        }
        var icon: String {
            switch self {
            case .model: return Ic.bolt
            case .parser: return Ic.server
            case .appearance: return Ic.palette
            case .automation: return Ic.bot
            case .about: return "info.circle"
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

    /// 连接三项(Base URL/模型/API Key)的签名;与最近一次成功测试一致才解锁能力选项。
    private var llmConnectionKey: String {
        let base = llmBaseUrl.trimmingCharacters(in: .whitespaces)
        let model = llmModel.trimmingCharacters(in: .whitespaces)
        let typedKey = llmApiKey.trimmingCharacters(in: .whitespaces)
        return "\(base)|\(model)|\(typedKey.isEmpty ? "saved" : typedKey)"
    }

    private var llmGateOpen: Bool { llmCaps != nil && llmTestedKey == llmConnectionKey }

    private var reasoningOptions: [(String, String)] {
        let labels = ["off": "关闭", "none": "关闭", "minimal": "最低", "low": "低", "medium": "中", "high": "高", "xhigh": "最高"]
        let levels = llmGateOpen ? (llmCaps?.levels ?? ["off", "low", "medium", "high"]) : ["off", "low", "medium", "high"]
        return levels.map { ($0, labels[$0] ?? $0) }
    }

    private var maxOutputRange: ClosedRange<Int> {
        guard let limit = llmCaps?.maxOutputDefault, limit > 256 else { return 256...AnalysisEngine.fallbackOutputLimit }
        return 256...limit
    }

    var body: some View {
        WorkspaceSplitLayout(compact: isCompact, collapsed: false, temporarilyExpanded: .constant(false)) {
            sidebarCard
        } content: {
            sectionCard
        }
        .task {
            hydrateAppearance()
            hydrateFromSettings()
            if updateStore.wantsUpdateSettings { tab = .about; updateStore.wantsUpdateSettings = false }
        }
        .onChange(of: updateStore.wantsUpdateSettings) { _, requested in
            if requested { tab = .about; updateStore.wantsUpdateSettings = false }
        }
        .overlay(alignment: .bottomTrailing) { noticeOverlay }
    }

    // MARK: sidebar

    private var sidebarCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    if isCompact {
                        Image.ic(item.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(tab == item ? palette.accent : palette.gray500)
                            .frame(width: 40, height: 40)
                            .background(tab == item ? palette.accentSoft : Color.clear, in: Circle())
                            .contentShape(Circle())
                    } else {
                        HStack(spacing: 7) {
                            Image.ic(item.icon)
                                .font(.system(size: 14))
                                .frame(width: 22)
                                .foregroundStyle(tab == item ? palette.accent : palette.gray500)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label).font(.system(size: 15, weight: tab == item ? .semibold : .regular))
                                    .foregroundStyle(tab == item ? palette.accent : palette.gray500)
                            }
                            Spacer(minLength: 0)
                            Image.ic(Ic.chevronRight).font(.system(size: 12)).foregroundStyle(palette.gray400)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous).fill(tab == item ? palette.accentSoft : Color.clear))
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .help(item.label).accessibilityLabel(item.label)
            }

            Spacer(minLength: 0)

            if !isCompact {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image.ic(settingsKnown && llmReady && mineruReady ? Ic.check : Ic.shieldAlert)
                        .font(.system(size: 16))
                        .foregroundStyle(settingsKnown && llmReady && mineruReady ? palette.success : palette.accent)
                    Text("使用前置条件").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.gray700)
                }
                readinessRow("AI 模型", ready: settingsKnown ? llmReady : nil, awaitingAuthorization: settingsStore.credentialNeedsAuthorization(.llmApiKey))
                readinessRow("PDF 解析", ready: settingsKnown ? mineruReady : nil, awaitingAuthorization: mineruMode != "local" && settingsStore.credentialNeedsAuthorization(.mineruToken))
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidInset(tint: palette.accentFaint)
            }
        }
        .padding(isCompact ? 6 : 18)
        .liquidPanel(elevated: true)
    }

    private var settingsKnown: Bool { settingsStore.settings != nil }

    /// 就绪清单行:配置完成显示绿色对勾,否则提示待配置;设置读不到时无法确认。
    private func readinessRow(_ label: String, ready: Bool?, awaitingAuthorization: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(palette.gray600)
            Spacer(minLength: 0)
            switch ready {
            case .some(true):
                HStack(spacing: 4) {
                    Image.ic(Ic.check).font(.system(size: 11, weight: .semibold))
                    Text("已就绪").font(.system(size: 12))
                }
                .foregroundStyle(palette.success)
            case .some(false):
                Text(awaitingAuthorization ? "待解锁" : "待配置").font(.system(size: 12)).foregroundStyle(palette.gray400)
            case .none:
                Text("无法确认").font(.system(size: 12)).foregroundStyle(palette.gray400)
            }
        }
    }

    // MARK: content

    private var sectionCard: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tab != .about && settingsStore.credentialsNeedAuthorization {
                        credentialAccessNotice
                    }
                    sectionHeader
                    Group {
                        switch tab {
                        case .model: modelSection
                        case .parser: parserSection
                        case .appearance: appearanceSection
                        case .automation: automationSection
                        case .about: aboutSection
                        }
                    }
                    sectionNotes.padding(.top, 24)
                    // The footer shares the form's scroll content. The viewport
                    // is a minimum height, so long forms push it below the text.
                    Spacer(minLength: 32)
                    if tab != .automation && tab != .about {
                        HStack {
                            ToolbarButton(title: "保存配置", icon: Ic.save, kind: .primary, busy: saving) {
                                switch tab {
                                case .model: saveLLM()
                                case .parser: saveMinerU()
                                case .appearance: saveAppearance()
                                case .automation, .about: break
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, PageTitleSpec.contentInset)
                .padding(.top, PageTitleSpec.contentInset)
                .padding(.bottom, 66)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }.liquidPanel(elevated: true).frame(maxHeight: .infinity)
    }

    private var credentialAccessNotice: some View {
        HStack(spacing: 12) {
            Text(settingsStore.credentialError.isEmpty
                 ? "已保存的凭据待解锁。在系统窗口中授权后，AI、PDF 解析与 MCP 共用本次读取结果。"
                 : settingsStore.credentialError)
                .font(.system(size: 12)).foregroundStyle(palette.gray600)
            Spacer(minLength: 0)
            Button(settingsStore.readingCredentials ? "正在解锁…" : "解锁已保存凭据") {
                Task {
                    await settingsStore.readSavedCredentials(allowInteraction: true)
                    await mcpStore.restore()
                }
            }
            .buttonStyle(LiquidActionButtonStyle())
            .disabled(settingsStore.readingCredentials)
        }
        .padding(12)
        .liquidInset(cornerRadius: CornerRadius.inset)
        .padding(.bottom, 20)
    }

    private var sectionHeader: some View {
        let configured = tab == .model ? llmReady : tab == .parser ? mineruReady : tab == .automation ? mcpStore.running : true
        let title = tab == .model ? "AI 模型连接" : tab == .parser ? "PDF 解析" : tab == .automation ? "MCP 连接" : tab.label
        let awaitingAuthorization = tab == .model ? settingsStore.credentialNeedsAuthorization(.llmApiKey) : tab == .parser && mineruMode != "local" ? settingsStore.credentialNeedsAuthorization(.mineruToken) : false
        let status = tab == .automation ? (mcpStore.running ? "运行中" : "未运行") : (configured ? "已配置" : awaitingAuthorization ? "待解锁" : "需要配置")
        return HStack(alignment: .center, spacing: 18) {
            Text(title).font(PageTitleSpec.font).foregroundStyle(palette.gray900)
            Spacer(minLength: 0)
            if tab != .about {
                Label(status, systemImage: configured ? Ic.check : "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(configured ? palette.success : palette.gray500)
                    .padding(.horizontal, 12).frame(height: 30)
                    .liquidTool(tint: configured ? palette.success.opacity(0.1) : nil)
            }
        }
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.gray200).frame(height: 1) }
        .padding(.bottom, 31)
    }

    private var notes: [String] {
        switch tab {
        case .model:
            return ["兼容 OpenAI Chat Completions 接口，配置用于全文翻译、逻辑归纳、论文问答与笔记生成。API Key 保存在本机钥匙串。",
                llmGateOpen ? "已获取模型能力，确认思考强度与对话输出上限后保存配置。" : "填好配置后点击「测试连通性」，即可选择思考强度与对话输出上限。",
                "长论文分段完整翻译后汇总全文分析；每段只生成一次，失败响应保留，供手动重试。"]
        case .parser:
            return [mineruMode == "local" ? "连接本机 MinerU Gradio 服务，无需 Token；MinerU.Chem 化学解析目前仅云端提供。" : "MinerU Token 保存在本机钥匙串。PDF 上传到解析服务后，Paperico 自动等待解析结果。",
                "可检索文字型 PDF 建议关闭强制 OCR，并开启公式与表格识别；扫描版或图片型 PDF 建议开启强制 OCR。"]
        case .appearance:
            return ["外观设置保存在本机，修改即时生效。正文字号仅影响论文正文，其他界面统一使用系统默认字体。",
                "背景透明度与玻璃透明度分别调节，文字和图标保持清晰。"]
        case .automation:
            return ["支持 MCP Streamable HTTP 的客户端可通过服务地址与访问 Token 连接，也可使用通用 JSON 配置。认证请求头为 Authorization: Bearer <Token>。",
                "提供 10 个只读工具及论文资源，不会触发解析或模型调用。Paperico 需要保持运行，关闭开关会断开连接。",
                "Token 保存在本机钥匙串。连接后可读取活动论文库中的正文、图像、方法、对话与笔记；更换 Token 后需更新客户端配置。"]
        case .about:
            return ["自动检查每天最多一次，只检测 GitHub 的正式发布版本。有新版本时提醒，可前往发布页下载并安装。"]
        }
    }

    private var sectionNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(notes, id: \.self) { text in Text(text).fixedSize(horizontal: false, vertical: true) }
        }
        .font(.system(size: 12.5)).foregroundStyle(palette.gray500).lineSpacing(4)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .liquidInset(cornerRadius: CornerRadius.inset)
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image("PapericoMark").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(palette.accent).frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 8) {
                    PapericoWordmark().frame(width: 146, height: 32)
                    Text("版本 \(updateStore.currentVersion) · 构建 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")")
                        .font(.system(size: 12)).foregroundStyle(palette.gray500)
                }
            }
            Text("将论文原文、双语精读、逻辑链与证据问答串联在一起的 macOS 阅读工作台。")
                .font(.system(size: 14)).foregroundStyle(palette.gray600)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                field("开发者") { Text("juliusloon") }
                field("开源许可") { Text("MIT License") }
            }
            .font(.system(size: 14)).padding(16)
            .liquidInset(cornerRadius: CornerRadius.inset)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { aboutLinks }
                VStack(alignment: .leading, spacing: 10) { aboutLinks }
            }
            Text("论文库、阅读进度、对话与笔记保存在本机；解析和 AI 请求由你配置的服务处理。")
                .font(.system(size: 12.5)).foregroundStyle(palette.gray500)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(palette.gray200).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                Text("软件更新").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.gray800)
                Toggle("自动检查新版本", isOn: Binding(get: { updateStore.automaticallyChecks }, set: { updateStore.automaticallyChecks = $0 }))
                    .toggleStyle(.switch)
                HStack(spacing: 10) {
                    ToolbarButton(title: "检查更新", icon: "arrow.triangle.2.circlepath", busy: updateStore.checking) {
                        Task { await updateStore.check(manual: true) }
                    }
                    if let release = updateStore.available, let url = release.pageURL {
                        ToolbarButton(title: "下载新版本", icon: "arrow.down.circle", kind: .primary) { openURL(url) }
                    }
                }
                if !updateStore.message.isEmpty {
                    Text(updateStore.message).font(.system(size: 13)).foregroundStyle(updateStore.failed ? palette.danger : palette.gray600)
                }
                if let date = updateStore.lastChecked {
                    Text("上次检查：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(palette.gray500)
                }
            }
            Text("© 2026 juliusloon").font(.system(size: 12)).foregroundStyle(palette.gray500)
        }
    }

    @ViewBuilder private var aboutLinks: some View {
        ToolbarButton(title: "项目主页", icon: "globe") { openURL(URL(string: "https://github.com/juliusloon/Paperico")!) }
        ToolbarButton(title: "反馈问题", icon: "bubble.left") { openURL(URL(string: "https://github.com/juliusloon/Paperico/issues")!) }
        ToolbarButton(title: "发布记录", icon: "clock") { openURL(URL(string: "https://github.com/juliusloon/Paperico/releases")!) }
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
    @ViewBuilder private func fieldRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if containerWidth < 720 {
            VStack(alignment: .leading, spacing: 18) { content() }
        } else {
            HStack(alignment: .center, spacing: 18) { content() }
        }
    }

    private func textFieldBinding(_ text: Binding<String>, placeholder: String) -> some View {
        FormTextField(text: text, placeholder: placeholder)
    }

    private func secretField(_ text: Binding<String>, placeholder: String, visible: Binding<Bool>) -> some View {
        FormSecretField(text: text, placeholder: placeholder, visible: visible)
    }

    private var automationSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle("允许 MCP 客户端只读访问", isOn: Binding(get: { mcpStore.enabled }, set: { mcpStore.setEnabled($0) }))
                .toggleStyle(.switch).disabled(mcpStore.busy)
            if mcpStore.busy { ProgressView("正在更新连接…") }
            if !mcpStore.error.isEmpty {
                Text(mcpStore.error).font(.system(size: 13)).foregroundStyle(palette.danger)
                if mcpStore.enabled && !mcpStore.running {
                    ToolbarButton(title: "重试连接", icon: Ic.refresh, disabled: mcpStore.busy) { mcpStore.retry() }
                }
            }
            if mcpStore.running {
                field("服务地址") {
                    HStack(spacing: 8) {
                        Text(mcpStore.endpoint).font(.system(size: 12)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RoundIconButton(systemName: "doc.on.doc", size: 30, title: "复制服务地址") { copyMCP(mcpStore.endpoint, label: "服务地址") }
                            .liquidTool()
                    }
                }
                field("访问 Token") {
                    HStack(spacing: 8) {
                        Text(showMCPToken ? mcpStore.token : "••••••••••••••••••••••••")
                            .font(.system(size: 12)).lineLimit(1).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        RoundIconButton(systemName: showMCPToken ? "eye.slash" : "eye", size: 30,
                            title: showMCPToken ? "隐藏 Token" : "显示 Token") { showMCPToken.toggle() }
                            .liquidTool()
                        RoundIconButton(systemName: "doc.on.doc", size: 30, title: "复制 Token") { copyMCP(mcpStore.token, label: "Token") }
                            .liquidTool()
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { mcpActions }
                    VStack(alignment: .leading, spacing: 10) { mcpActions }
                }
            }
        }
    }

    @ViewBuilder private var mcpActions: some View {
        ToolbarButton(title: "复制连接配置", icon: "doc.on.doc") { copyMCP(mcpStore.clientConfiguration, label: "连接配置") }
        ToolbarButton(title: "更换 Token", icon: "arrow.triangle.2.circlepath", disabled: mcpStore.busy) {
            mcpStore.rotateToken(); showMCPToken = false
        }
    }

    private func copyMCP(_ value: String, label: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
        notice = Notice(success: true, message: "\(label)已复制。")
    }

    // MARK: model tab

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            fieldRow {
                field("配置名称") {
                    textFieldBinding($llmName, placeholder: "例如：主要模型")
                }
                field("模型名称") {
                    textFieldBinding($llmModel, placeholder: "与服务商控制台的 model id 完全一致")
                }
            }
            field("Base URL") {
                textFieldBinding($llmBaseUrl, placeholder: "填写到 /v1，例如 https://api.openai.com/v1")
            }
            field("API Key") {
                HStack(spacing: 9) {
                    secretField(
                        $llmApiKey,
                        placeholder: llmReady
                            ? "已保存：\(settingsStore.settings?.modelProfiles.first?.apiKeyMasked ?? "")。留空会继续使用，不会覆盖。"
                            : settingsStore.credentialNeedsAuthorization(.llmApiKey) ? "已保存，解锁后可使用；留空不会覆盖。" : "填入服务商提供的 API Key，仅保存在本机钥匙串",
                        visible: $showLlmKey
                    )
                    ToolbarButton(title: "测试连通性", icon: Ic.testTube, busy: testingLlm) {
                        testLLM()
                    }
                }
            }
            fieldRow {
                field("思考强度") {
                    ReasoningSlider(selection: $llmReasoning, options: reasoningOptions)
                        .disabled(!llmGateOpen)
                        .opacity(llmGateOpen ? 1 : 0.55)
                }
                field("输出上限") {
                    FormStepper(title: "\(llmMaxTokens)", value: $llmMaxTokens, range: maxOutputRange, step: 256)
                        .disabled(!llmGateOpen)
                        .opacity(llmGateOpen ? 1 : 0.55)
                }
            }
            Toggle("允许对话参考论文库", isOn: $allowLibraryChat)
            Text("开启后，助手可按需把其他论文的摘要或原文发送给你配置的模型服务。关闭时仅使用当前论文。")
                .font(.system(size: 12)).foregroundStyle(palette.gray500)
            Text(settingsStore.llmProfile.supportsTools == true ? "支持工具调用" : "使用兼容检索模式（测试连通性后更新能力）")
                .font(.system(size: 12)).foregroundStyle(palette.gray500)
            Text("全文分析会按原文长度提高输出预算，并受服务端实际输出容量限制；默认预算为 65,536 tokens。对话使用上面的输出上限。")
                .font(.system(size: 12)).foregroundStyle(palette.gray500)
        }
    }

    // MARK: parser tab

    private var parserSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            field("解析方式") {
                SlidingChoice(selection: $mineruMode, options: [("cloud", "MinerU 云端 API"), ("local", "本地部署（Gradio 服务）")])
            }
            if mineruMode == "local" {
                field("本地服务地址") {
                    HStack(spacing: 9) {
                        textFieldBinding($mineruLocalUrl, placeholder: "指向 mineru-gradio 的 HTTP 地址，例如 http://127.0.0.1:7860")
                        ToolbarButton(title: "测试连接", icon: Ic.testTube, busy: testingMineru) {
                            testMinerU()
                        }
                    }
                }
            } else {
                field("Base URL") {
                    textFieldBinding($mineruBaseUrl, placeholder: "https://mineru.net/api/v4")
                }
                field("MinerU Token") {
                    HStack(spacing: 9) {
                        secretField(
                            $mineruApiKey,
                            placeholder: settingsStore.settings?.mineru.apiKeyConfigured == true
                                ? "已保存。留空保存不会覆盖。"
                                : settingsStore.credentialNeedsAuthorization(.mineruToken) ? "已保存，解锁后可使用；留空不会覆盖。" : "粘贴在 MinerU API 管理页面创建的 Token",
                            visible: $showMineruKey
                        )
                        ToolbarButton(title: "测试连接", icon: Ic.testTube, busy: testingMineru) {
                            testMinerU()
                        }
                    }
                }
            }
            field("解析模型") {
                if mineruMode == "local" {
                    SlidingChoice(selection: $mineruModelBackend, options: [("pipeline", "Pipeline"), ("vlm", "VLM Engine"), ("hybrid-engine", "Hybrid Engine")])
                } else {
                    SlidingChoice(selection: $mineruModelBackend, options: [("vlm", "VLM（推荐）"), ("pipeline", "Pipeline")])
                }
            }

            FlowChips(spacing: 16) {
                Toggle("公式识别", isOn: $mineruEnableFormula).toggleStyle(.switch).font(.system(size: 13))
                Toggle("表格识别", isOn: $mineruEnableTable).toggleStyle(.switch).font(.system(size: 13))
                Toggle("强制 OCR", isOn: $mineruIsOcr).toggleStyle(.switch).font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)

        }
    }

    // MARK: appearance tab

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            fieldRow {
                field("主题") {
                    SlidingChoice(selection: $appearanceTheme, options: [("light", "亮色"), ("dark", "暗色"), ("system", "跟随系统")], icons: ["light": "sun.max", "dark": "moon", "system": "display"])
                }
                field("正文字号") {
                    FormStepper(title: "\(appearanceFontSize)", value: $appearanceFontSize, range: 13...23)
                }
            }
            field("背景透明度") {
                HStack(spacing: 12) {
                    Slider(value: transparencyBinding, in: 0...50, step: 1)
                        .accessibilityLabel("背景透明度")
                    TextField("百分比", value: transparencyBinding, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 13))
                        .frame(width: 44)
                        .padding(8)
                        .liquidInset(cornerRadius: ControlSpec.radius)
                        .accessibilityLabel("背景透明度百分比")
                    Text("%").foregroundStyle(palette.gray500)
                }
            }
            field("强调色") {
                HStack(spacing: 9) {
                    accentSwatch
                    textFieldBinding($appearanceAccent, placeholder: "#275DCE")
                }
            }
            field("玻璃透明度") {
                HStack(spacing: 12) {
                    Slider(value: glassTransparencyBinding, in: 0...30, step: 1)
                        .accessibilityLabel("液态玻璃组件透明度")
                    TextField("百分比", value: glassTransparencyBinding, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(.system(size: 13)).frame(width: 44)
                        .padding(8).liquidInset(cornerRadius: ControlSpec.radius)
                        .accessibilityLabel("液态玻璃透明度百分比")
                    Text("%").foregroundStyle(palette.gray500)
                }
            }
        }
    }

    private var transparencyBinding: Binding<Double> {
        Binding(get: { appStore.backgroundTransparency }, set: { appStore.setBackgroundTransparency($0) })
    }

    private var glassTransparencyBinding: Binding<Double> {
        Binding(get: { appStore.glassTransparency }, set: { appStore.setGlassTransparency($0) })
    }

    /// 与保存按钮使用同一强调色和原生玻璃样式,避免预览与实际按钮颜色不同。
    private var accentSwatch: some View {
        let previewAccent = Palette.default(accentHex: appearanceAccent, dark: palette.dark).accent
        return Button {
            showAccentPicker = true
        } label: {
            Image.ic(Ic.penLine)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(LiquidActionButtonStyle(prominent: true, tint: previewAccent, horizontalPadding: 8, verticalPadding: 8))
        .controlSize(.large)
        .tint(previewAccent)
        .frame(width: ControlSpec.height, height: ControlSpec.height)
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
                        RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous)
                            .fill(Color(hex: hex) ?? palette.accent)
                            .overlay(
                                RoundedRectangle(cornerRadius: CornerRadius.inset, style: .continuous)
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

    // MARK: actions

    /// 外观表单从客户端本地真身(AppStore/LocalPrefs)回填,与服务是否可达无关。
    private func hydrateAppearance() {
        appearanceAccent = appStore.accentColor
        appearanceTheme = appStore.theme
        appearanceFontSize = LocalPrefs.readingFontSize ?? settingsStore.settings?.appearance.readingFontSize ?? 18
    }

    private func hydrateFromSettings() {
        guard let settings = settingsStore.settings else { return }

        let mineru = settings.mineru
        mineruMode = mineru.mode
        mineruBaseUrl = mineru.baseUrl
        mineruLocalUrl = mineru.localUrl.isEmpty ? "http://127.0.0.1:7860" : mineru.localUrl
        let options = mineru.defaultOptions
        mineruIsOcr = options.isOcr
        mineruEnableFormula = options.enableFormula
        mineruEnableTable = options.enableTable
        mineruModelBackend = options.modelBackend

        if let profile = settings.modelProfiles.first {
            llmId = profile.id
            llmName = profile.name
            llmBaseUrl = profile.baseUrl
            llmModel = profile.model
            llmMaxTokens = profile.maxTokens ?? AnalysisEngine.defaultMaxTokens
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
            notice = Notice(success: true, message: "模型配置已保存，并已分配给解析、总结、对话和笔记流程。")
            hydrateFromSettings()
            // 保存后密钥从"已输入"转为"留空用已存";连接未变时保持能力选项解锁。
            if llmGateOpen { llmTestedKey = llmConnectionKey }
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
                    modelBackend: mineruModelBackend
                )
            )
            try await settingsStore.saveMinerU(mineru)
            mineruApiKey = ""
            notice = Notice(success: true, message: "MinerU 配置已保存。")
        }
    }

    /// 外观属于客户端本地设置:写入 UserDefaults 即时生效,与任何服务无关。
    private func saveAppearance() {
        let accent = appearanceAccent.trimmingCharacters(in: .whitespaces)
        appStore.setAccent(accent)
        appStore.setTheme(appearanceTheme)
        LocalPrefs.readingFontSize = appearanceFontSize
        notice = Notice(success: true, message: "阅读外观已保存。")
    }

    /// 测试连通性:直接探测模型服务(不落库);成功后记录能力并解锁思考强度/输出上限。
    private func testLLM() {
        notice = nil
        let profile = normalizedProfile()
        if profile.baseUrl.isEmpty {
            notice = Notice(success: false, message: "请先填写 Base URL。")
            return
        }
        if profile.model.isEmpty {
            notice = Notice(success: false, message: "请先填写模型名称。")
            return
        }
        if profile.apiKey.isEmpty && !llmReady {
            notice = Notice(success: false, message: settingsStore.credentialNeedsAuthorization(.llmApiKey) ? "请先点击「解锁已保存凭据」，再测试连通性。" : "请先填写 API Key，再测试连通性。")
            return
        }
        testingLlm = true
        Task {
            defer { testingLlm = false }
            let result = await settingsStore.testLLM(
                baseUrl: profile.baseUrl, apiKey: profile.apiKey, model: profile.model
            )
            notice = Notice(success: result.success, message: result.message)
            guard result.success else { return }
            let levels = result.supportsReasoning == false
                ? ["off"]
                : (result.reasoningLevels ?? ["off", "low", "medium", "high"])
            llmCaps = LLMCaps(
                levels: levels,
                maxOutputDefault: result.defaultMaxOutputTokens
            )
            llmTestedKey = llmConnectionKey
            if result.supportsReasoning == false { llmReasoning = "off" }
            if let limit = result.defaultMaxOutputTokens, limit > 0 {
                llmMaxTokens = limit
            }
        }
    }

    private func testMinerU() {
        notice = nil
        testingMineru = true
        Task {
            defer { testingMineru = false }
            let result = await settingsStore.testMinerU(
                mode: mineruMode,
                baseUrl: mineruBaseUrl.trimmingCharacters(in: .whitespaces),
                localUrl: mineruLocalUrl.trimmingCharacters(in: .whitespaces),
                apiKey: mineruApiKey.trimmingCharacters(in: .whitespaces)
            )
            notice = Notice(success: result.success, message: result.message)
        }
    }

    private func runAction(_ action: @escaping () async throws -> Void) {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await action()
            } catch {
                notice = Notice(success: false, message: ApiFailure.wrap(error).errorDescription ?? "操作失败，请检查配置后重试。")
            }
        }
    }

    // MARK: notice overlay (bottom-right card)

    private var noticeOverlay: some View {
        Group {
            if let notice {
                ViewThatFits(in: .horizontal) {
                    noticeContent(notice).fixedSize(horizontal: true, vertical: true)
                    noticeContent(notice)
                }
                .padding(13)
                .liquidPanel()
                .frame(maxWidth: min(320, containerWidth - 40), alignment: .trailing)
                .padding(20)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notice)
    }

    private func noticeContent(_ notice: Notice) -> some View {
        HStack(spacing: 8) {
            Image.ic(notice.success ? Ic.check : Ic.close).font(.system(size: 13))
            Text(notice.message).font(.system(size: 12)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button { self.notice = nil } label: {
                Image.ic(Ic.close).font(.system(size: 10)).foregroundStyle(palette.gray500)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).noFocusRing().accessibilityLabel("关闭提示")
        }
        .foregroundStyle(notice.success ? palette.success : palette.danger)
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
