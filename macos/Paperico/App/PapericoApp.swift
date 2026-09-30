import SwiftUI

@main
struct PapericoApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .environment(appModel.appStore)
                .environment(appModel.settingsStore)
                .environment(appModel.projectsStore)
                .environment(appModel.papersStore)
                .environment(appModel.readerStore)
                .environment(appModel.chatStore)
                .environment(appModel.router)
                .environment(\.palette, appModel.palette)
                .environment(\.apiClient, appModel.client)
                .preferredColorScheme(appModel.preferredScheme)
                .tint(appModel.palette.accent)
                #if os(macOS)
                .frame(minWidth: 680, minHeight: 560)
                #endif
        }
        #if os(macOS)
        // 去掉系统标题栏:红绿灯悬浮于窗口左上角,由左侧栏顶部承接
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        #endif
    }
}

/// Composition root: owns the api client and every store (mirrors stores/index.ts wiring).
@MainActor
@Observable
final class AppModel {
    let client: ApiClient
    let router: Router
    let appStore: AppStore
    let settingsStore: SettingsStore
    let projectsStore: ProjectsStore
    let papersStore: PapersStore
    let readerStore: ReaderStore
    let chatStore: ChatStore

    init() {
        let client = ApiClient()
        let settingsStore = SettingsStore(client: client)
        self.client = client
        self.router = Router()
        self.settingsStore = settingsStore
        self.appStore = AppStore(settingsStore: settingsStore)
        self.projectsStore = ProjectsStore(client: client)
        self.papersStore = PapersStore(client: client)
        self.readerStore = ReaderStore(client: client)
        self.chatStore = ChatStore(client: client)

        // Mirror applyAppearance(): backend appearance resets local overrides.
        settingsStore.onSettingsApplied = { [weak appStore] in
            appStore?.syncFromSettings()
        }
    }

    /// Accent + theme mode pulled from backend appearance settings.
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
        default:
            #if os(iOS)
            return UITraitCollection.current.userInterfaceStyle == .dark
            #else
            if let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
                return match == .darkAqua
            }
            return false
            #endif
        }
    }

    func onAppear() {
        if settingsStore.settings == nil && !settingsStore.loading {
            Task { await settingsStore.fetch() }
        }
    }
}

/// Mirrors useAppStore: theme + accent color, applied from appearance settings.
@MainActor
@Observable
final class AppStore {
    private unowned let settingsStore: SettingsStore

    var themeOverride: String?
    var accentOverride: String?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    var theme: String {
        themeOverride ?? settingsStore.settings?.appearance.themeMode ?? "system"
    }

    var accentColor: String {
        let fallback = "#2F6FED"
        let accent = accentOverride ?? settingsStore.settings?.appearance.accentColor ?? fallback
        return accent.isEmpty ? fallback : accent
    }

    func setTheme(_ t: String) { themeOverride = t }
    func setAccent(_ hex: String) { accentOverride = hex }
    func syncFromSettings() {
        themeOverride = nil
        accentOverride = nil
    }
}

/// Mirrors react-router routes: /, /library, /paper/:id, /settings, /methods.
@MainActor
@Observable
final class Router: Hashable {
    enum Page: Hashable {
        case home
        case library
        case methods
        case settings
        case reader(paperId: String)
    }

    var page: Page = .home

    static func == (lhs: Router, rhs: Router) -> Bool { lhs.page == rhs.page }
    func hash(into hasher: inout Hasher) { hasher.combine(page) }

    func go(_ page: Page) { self.page = page }

    /// WorkspaceNav offers a shortcut to the last opened paper (paperico:last-paper).
    var lastPaperId: String? {
        get { LocalPrefs.lastPaperId }
        set { LocalPrefs.lastPaperId = newValue }
    }
}
