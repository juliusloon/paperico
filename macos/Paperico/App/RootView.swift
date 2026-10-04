import SwiftUI

/// Root layout (mirrors App.tsx): routed pages;每页自带工作台导航
/// (所有宽度均贴底左侧,紧凑宽度收成圆钮)。
struct RootView: View {
    @Environment(\.palette) private var palette
    @Environment(\.backgroundOpacity) private var backgroundOpacity
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(AppModel.self) private var appModel
    @Environment(Router.self) private var router
    @Environment(UpdateStore.self) private var updateStore
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if !appModel.ready {
                    startupView
                } else {
                    routedPage
                        // A route owns its layout; only its opacity participates
                        // in navigation, rather than interpolating page geometry.
                        .transition(.opacity)
                        .id(router.page)
                        .disabled(router.libraryManagement != nil)
                        .accessibilityHidden(router.libraryManagement != nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlayPreferenceValue(WorkspaceMenuPreferenceKey.self) { requests in
                WorkspaceMenuOverlay(requests: router.libraryManagement == nil ? requests : [])
            }
            .overlay {
                if let section = router.libraryManagement {
                    LibraryManagementOverlay(section: section) { router.libraryManagement = nil }
                }
            }
            .environment(\.containerWidth, geo.size.width)
            // 红绿灯留白:单一来源,页面用 trafficLightTopPadding() 消费。
            .environment(\.trafficLightClearance, topClearance)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: router.page)
        }
        #if os(macOS)
        // 顶栏收窄:系统在 hiddenTitleBar 下仍保留 ~32pt 顶部安全区,连同页面补白
        // 会叠出一块空顶栏。这里忽略它,让页面从窗口顶边起排,高度全部交给
        // WindowChrome.topClearance 这一个来源控制。
        .ignoresSafeArea(.container, edges: .top)
        #endif
        .modifier(ReaderExitGuard())
        .focusedSceneValue(\.readerAnnotationStore, readerCommandsStore)
        #if os(macOS)
        // The native window draws the canvas, including its rounded edges.
        .background(Color.clear)
        #else
        .background(palette.appBase.opacity(reduceTransparency ? 1 : backgroundOpacity))
        #endif
        // 主题/强调色切换的全局交叉淡化:palette 变化牵动的所有颜色(背景、文字、
        // 描边、卡片)在同一事务里过渡,而不是一帧硬切。appBase 捕捉明暗翻转,
        // accent 捕捉换色;树内其他 .animation(value:) 各有 value 门控,不会冲突。
        .animation(.easeInOut(duration: 0.2), value: palette.appBase)
        .animation(.easeInOut(duration: 0.2), value: palette.accent)
        .task { await appModel.bootstrap(); await updateStore.check() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await updateStore.check() } }
        }
        .alert("发现 Paperico 新版本", isPresented: Binding(get: { updateStore.showPrompt }, set: { if !$0 { updateStore.dismissPrompt() } })) {
            Button("前往更新") {
                if let url = updateStore.available?.pageURL { openURL(url) }
                updateStore.dismissPrompt()
            }
            Button("稍后", role: .cancel) { updateStore.dismissPrompt() }
        } message: {
            Text("\(updateStore.currentVersion) → \(updateStore.available?.versionLabel ?? "")。下载并安装新版本后即可完成更新。")
        }
        .onAppear {
            appModel.systemIsDark = colorScheme == .dark
            AppBootstrap.install()
            applyWindowChrome()
        }
        // 主题切换时同步刷新窗口背景,避免深色模式下出现系统灰色的窗口底色接缝。
        .onChange(of: palette.appBase) { _, _ in applyWindowChrome() }
        .onChange(of: backgroundOpacity) { _, _ in applyWindowChrome() }
        .onChange(of: reduceTransparency) { _, _ in applyWindowChrome() }
        // 系统明暗切换(或主题在 system 与显式明暗间切换)时回写 AppModel,
        // 驱动 palette / tint / preferredColorScheme 全量重算。
        .onChange(of: colorScheme) { _, newValue in
            appModel.systemIsDark = newValue == .dark
        }
    }

    @ViewBuilder private var routedPage: some View {
        switch router.page {
        case .home: HomePage()
        case .library: LibraryPage()
        case .methods: MethodsPage()
        case .settings: SettingsPage()
        case .reader(let paperId): ReaderPage(paperId: paperId)
        }
    }

    private var startupView: some View {
        VStack(spacing: 18) {
            if appModel.startupError.isEmpty {
                ProgressView("正在打开本地论文库…")
            } else {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 36)).foregroundStyle(palette.danger)
                Text("论文库暂时无法打开").font(.title2)
                Text(appModel.startupError).font(.body).textSelection(.enabled)
                Button("重新读取") { Task { await appModel.bootstrap() } }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(palette.accentForeground)
            }
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readerCommandsStore: ReaderStore? {
        if case .reader = router.page { return appModel.readerStore }
        return nil
    }

    private var topClearance: CGFloat {
        #if os(macOS)
        WindowChrome.topClearance
        #else
        0
        #endif
    }

    private func applyWindowChrome() {
        #if os(macOS)
        WindowChrome.applyToAll(baseColor: NSColor(palette.dark ? palette.appBase : palette.gray50), opacity: reduceTransparency ? 1 : backgroundOpacity)
        #endif
    }
}
