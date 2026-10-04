import SwiftUI

/// Composition root:本地数据层 + 全部 store(纯原生,无任何后端进程)。
@MainActor
@Observable
final class AppModel {
    let library: PaperLibrary
    let router: Router
    let appStore: AppStore
    let settingsStore: SettingsStore
    let pipeline: PaperPipeline
    let projectsStore: ProjectsStore
    let papersStore: PapersStore
    let readerStore: ReaderStore
    let chatStore: ChatStore
    let mcpStore: MCPStore
    let updateStore = UpdateStore()

    /// 视图通过环境取用的本地服务句柄(actor 引用)。
    let services: AppServices

    private(set) var ready = false
    private(set) var startupError = ""
    private var bootstrapping = false

    init() {
        let library = PaperLibrary()
        let settingsStore = SettingsStore()
        let pipeline = PaperPipeline(library: library, settings: settingsStore)
        self.library = library
        self.settingsStore = settingsStore
        self.pipeline = pipeline
        self.router = Router()
        self.appStore = AppStore(settingsStore: settingsStore)
        self.projectsStore = ProjectsStore(library: library)
        self.papersStore = PapersStore(library: library, pipeline: pipeline)
        self.readerStore = ReaderStore(library: library)
        self.chatStore = ChatStore(library: library, settings: settingsStore)
        self.mcpStore = MCPStore(library: library)
        self.services = AppServices(library: library, pipeline: pipeline)

        mcpStore.onCredentialsRead = { [weak settingsStore] in
            await settingsStore?.readSavedCredentials()
        }

        // 启动即装载本地论文库(含中断对账);设置本地合成,无需网络。
        // 合成设置刷新时给本地外观补齐缺失项(一次性迁移),不覆盖本地选择。
        settingsStore.onSettingsApplied = { [weak appStore] in
            appStore?.syncFromSettings()
        }
    }

    /// 跟随系统模式下的系统外观解析结果。必须放在 @Observable 存储属性上,
    /// 由 RootView 从 SwiftUI 的 `\.colorScheme` 环境回写:系统明暗切换才会
    /// 驱动 palette / tint / 窗口背景重算(NSApp.effectiveAppearance 只是
    /// 一次性快照,外观变化不产生任何可观察通知)。
    var systemIsDark = AppModel.currentSystemIsDark

    /// Accent + theme mode from local appearance preferences.
    var palette: Palette {
        Palette.default(accentHex: appStore.accentColor, dark: colorSchemeIsDark)
    }

    var preferredScheme: ColorScheme? {
        switch appStore.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil // follow system
        }
    }

    private var colorSchemeIsDark: Bool {
        switch appStore.theme {
        case "dark": return true
        case "light": return false
        default: return systemIsDark
        }
    }

    /// 首帧初值,只为避免深色系统下启动瞬间的浅色闪烁;随后由 RootView 持续校正。
    private static var currentSystemIsDark: Bool {
        #if os(iOS)
        return UITraitCollection.current.userInterfaceStyle == .dark
        #else
        if let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            return match == .darkAqua
        }
        return false
        #endif
    }

    func bootstrap() async {
        guard !ready, !bootstrapping else { return }
        bootstrapping = true
        startupError = ""
        defer { bootstrapping = false }
        AppBootstrap.install()
        do {
            try await library.load()
            ready = true
            await settingsStore.fetch()
            await mcpStore.restore()
        } catch {
            startupError = ApiFailure.wrap(error).localizedDescription
        }
    }
}
