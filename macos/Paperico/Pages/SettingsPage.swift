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
    @State private var llmMaxTokens = 8192
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
        case model, parser, appearance, automation
        var label: String {
            switch self {
            case .model: return "AI 模型"
            case .parser: return "PDF 解析"
            case .appearance: return "阅读外观"
            case .automation: return "MCP 连接"
            }
        }
        var description: String {
            switch self {
            case .model: return "翻译、总结与问答"
            case .parser: return "MinerU 云端或本地部署"
            case .appearance: return "主题、强调色与字号"
            case .automation: return "外部助手只读访问论文库"
            }
        }
        var icon: String {
            switch self {
            case .model: return Ic.bolt
            case .parser: return Ic.server
            case .appearance: return Ic.palette
            case .automation: return Ic.bot
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
        guard let limit = llmCaps?.maxOutputDefault, limit > 256 else { return 256...32768 }
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
                                Text(item.description).font(.system(size: 12)).foregroundStyle(palette.gray400)
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
                readinessRow("AI 模型", ready: settingsKnown ? llmReady : nil)
                readinessRow("PDF 解析", ready: settingsKnown ? mineruReady : nil)
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
    private func readinessRow(_ label: String, ready: Bool?) -> some View {
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
                Text("待配置").font(.system(size: 12)).foregroundStyle(palette.gray400)
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
                    if settingsStore.credentialsNeedAuthorization || (!llmReady && !settingsStore.llmProfile.model.isEmpty) {
                        credentialAccessNotice
                    }
                    sectionHeader
                    Group {
                        switch tab {
                        case .model: modelSection
                        case .parser: parserSection
                        case .appearance: appearanceSection
                        case .automation: automationSection
                        }
                    }
                    // The footer shares the form's scroll content. The viewport
                    // is a minimum height, so long forms push it below the text.
                    Spacer(minLength: 32)
                    if tab != .automation {
                        HStack {
                            ToolbarButton(title: "保存配置", icon: Ic.save, kind: .primary, busy: saving) {
                                switch tab {
                                case .model: saveLLM()
                                case .parser: saveMinerU()
                                case .appearance: saveAppearance()
                                case .automation: break
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, containerWidth < 650 ? 16 : 30)
                .padding(.top, containerWidth < 650 ? 16 : 30)
                .padding(.bottom, 66)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }.liquidPanel(elevated: true).frame(maxHeight: .infinity)
    }

    private var credentialAccessNotice: some View {
        HStack(spacing: 12) {
            Text(settingsStore.credentialsNeedAuthorization
                 ? "已保存的凭据需要钥匙串授权，本地论文库仍可正常使用。"
                 : "如果以前保存过 API Key，可重新读取系统钥匙串中的凭据。")
                .font(.system(size: 12)).foregroundStyle(palette.gray600)
            Spacer(minLength: 0)
            Button(settingsStore.readingCredentials ? "正在读取…" : "读取已保存凭据") {
                Task { await settingsStore.readSavedCredentials(allowInteraction: true) }
            }
            .buttonStyle(.bordered)
            .disabled(settingsStore.readingCredentials)
        }
        .padding(12)
        .liquidInset(cornerRadius: CornerRadius.inset)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var sectionHeader: some View {
        let (kicker, title, description, configured): (String, String, String, Bool) = {
            switch tab {
            case .model:
                return ("MODEL CONNECTION", "AI 模型连接",
                        "使用 OpenAI-compatible Chat Completions 接口。API Key 保存在本机钥匙串中，一个配置自动用于翻译、逻辑归纳、Chatbot 和笔记生成。", llmReady)
            case .parser:
                let local = mineruMode == "local"
                return ("DOCUMENT PARSER", "MinerU 精准解析",
                        local ? "调用本机部署的 MinerU Gradio 服务（如 Docker 版 mineru-gradio），无需 Token；MinerU.Chem 化学解析目前仅云端提供。"
                              : "MinerU Token 保存在本机钥匙串中。本地 PDF 会申请官方签名上传地址，上传后自动轮询批任务。",
                        mineruReady)
            case .appearance:
                return ("READING APPEARANCE", "阅读外观", "保存在本机 App 中，只影响界面显示，修改即时生效。", true)
            case .automation:
                return ("MCP CONNECTION", "连接外部 AI 助手", "允许兼容 MCP 的客户端读取论文、正文、图像、方法索引、对话与笔记。客户端如何使用或发送这些内容取决于它的设置。", mcpStore.running)
            }
        }()

        let statusLabel = tab == .automation ? (mcpStore.running ? "运行中" : "未运行") : (configured ? "已配置" : "需要配置")
        let statusColor = tab == .automation && !mcpStore.enabled ? palette.gray500 : (configured ? palette.success : palette.danger)

        HStack(alignment: .top, spacing: containerWidth < 650 ? 12 : 30) {
            VStack(alignment: .leading, spacing: 8) {
                Text(kicker).font(.system(size: 10, weight: .bold)).kerning(1.6).foregroundStyle(palette.accent)
                Text(title).font(.reading(containerWidth < 650 ? 24 : 30, weight: .medium)).foregroundStyle(palette.gray900).padding(.vertical, 4)
                Text(description).font(.system(size: 14.5)).lineSpacing(6).foregroundStyle(palette.gray500)
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 0)
            Label(statusLabel, systemImage: configured ? Ic.check : (tab == .automation ? "pause.circle" : "exclamationmark.circle"))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 12)
            .frame(height: 30, alignment: .center)
            .fixedSize(horizontal: true, vertical: false)
            .liquidTool(tint: statusColor.opacity(0.1))
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
                .toggleStyle(.switch)
                .disabled(mcpStore.busy)
            Text("提供 10 个只读工具及论文资源。读取不会触发 MinerU、LLM 调用或修改论文。Paperico 必须保持运行，关闭开关会立即断开连接。")
                .font(.system(size: 13)).foregroundStyle(palette.gray500).lineSpacing(5)
            if mcpStore.busy {
                ProgressView("正在更新连接…")
            }
            if !mcpStore.error.isEmpty {
                Text(mcpStore.error).font(.system(size: 13)).foregroundStyle(palette.danger)
                if mcpStore.enabled && !mcpStore.running {
                    Button("重试连接") { mcpStore.retry() }.disabled(mcpStore.busy)
                }
            }
            if mcpStore.running {
                field("服务地址") {
                    Text(mcpStore.endpoint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                field("访问 Token") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(showMCPToken ? mcpStore.token : "••••••••••••••••••••••••")
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Button(showMCPToken ? "隐藏 Token" : "显示 Token") { showMCPToken.toggle() }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("复制 Cursor 配置") { copyMCP(mcpStore.clientConfiguration) }
                        Button("复制 VS Code 配置") { copyMCP(mcpStore.vscodeConfiguration) }
                        Button("复制 Claude Code 命令") { copyMCP(mcpStore.claudeCommand) }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("复制 Cursor 配置") { copyMCP(mcpStore.clientConfiguration) }
                        Button("复制 VS Code 配置") { copyMCP(mcpStore.vscodeConfiguration) }
                        Button("复制 Claude Code 命令") { copyMCP(mcpStore.claudeCommand) }
                    }
                }
                Button("更换 Token 并断开现有连接") { mcpStore.rotateToken(); showMCPToken = false }
                    .disabled(mcpStore.busy)
                Text("Token 保存在系统钥匙串。拿到 Token 的本机程序可以读取整个活动论文库，请仅复制给你信任的客户端。更换后需更新客户端配置。")
                    .font(.system(size: 12)).foregroundStyle(palette.gray500).lineSpacing(5)
            }
        }
    }

    private func copyMCP(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
        notice = Notice(success: true, message: "连接配置已复制。")
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
                            : "填入服务商提供的 API Key，仅保存在本机钥匙串",
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
            Text(llmGateOpen
                 ? "已获取该模型能力，确认思考强度与对话输出上限后，点击「保存配置」生效。"
                 : "填好配置名称、模型、Base URL 与 API Key，点击「测试连通性」后即可选择思考强度与对话输出上限。")
                .font(.system(size: 12.5))
                .lineSpacing(4)
                .foregroundStyle(palette.gray400)
            Text("全文翻译与分析合并为一次请求，输出容量按论文长度估算并受模型上限限制。")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.gray400)

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
                                : "粘贴在 MinerU API 管理页面创建的 Token",
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

            Text("对于可检索文字型 PDF，建议关闭“强制 OCR”，公式与表格识别保持开启；对于扫描版或图片型 PDF，建议开启“强制 OCR”。")
                .font(.system(size: 13))
                .lineSpacing(4)
                .foregroundStyle(palette.gray500)
                .padding(.leading, 13)
                .overlay(alignment: .leading) { Rectangle().fill(palette.accent).frame(width: 2) }
                .padding(.vertical, 11)

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
            notice = Notice(success: false, message: "请先填写 API Key，再测试连通性。")
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
