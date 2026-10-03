import SwiftUI

/// Mirrors useAppStore: theme + accent color, applied from appearance settings.
///
/// 外观是纯客户端设置:真身在 LocalPrefs(UserDefaults),修改即时生效,
/// 与本机数据服务是否启动无关。后端 appearance 字段只在本地从未设置过时
/// 做一次性迁移来源,之后绝不回写覆盖用户的本地选择。
@MainActor
@Observable
final class AppStore {
    private unowned let settingsStore: SettingsStore

    /// 主题/强调色的可观察真身:持久化仍在 LocalPrefs,但值必须落在 @Observable
    /// 存储属性上 —— 计算属性只读 UserDefaults 不产生变更通知,设置页保存后
    /// PapericoApp.body 里的 preferredColorScheme / tint / palette 环境不会重算,
    /// 界面要等后端往返碰巧更新 settings 才变(服务不可达时永远不变)。
    private(set) var theme: String
    private(set) var accentColor: String
    private(set) var backgroundTransparency: Double
    var backgroundOpacity: Double { 1 - backgroundTransparency / 100 }
    private(set) var glassTransparency: Double
    var glassOpacity: Double { 1 - glassTransparency / 100 }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.theme = LocalPrefs.themeMode ?? "system"
        self.backgroundTransparency = LocalPrefs.backgroundTransparency
        self.glassTransparency = LocalPrefs.glassTransparency
        self.accentColor = Self.resolveAccent(local: LocalPrefs.accentColor, settings: settingsStore.settings)
    }

    func setTheme(_ t: String) {
        LocalPrefs.themeMode = t
        theme = LocalPrefs.themeMode ?? settingsStore.settings?.appearance.themeMode ?? "system"
    }

    func setAccent(_ hex: String) {
        LocalPrefs.accentColor = hex
        accentColor = Self.resolveAccent(local: LocalPrefs.accentColor, settings: settingsStore.settings)
    }

    func setBackgroundTransparency(_ value: Double) {
        LocalPrefs.backgroundTransparency = value
        backgroundTransparency = LocalPrefs.backgroundTransparency
    }

    func setGlassTransparency(_ value: Double) {
        LocalPrefs.glassTransparency = value
        glassTransparency = LocalPrefs.glassTransparency
    }

    func syncFromSettings() {
        guard let appearance = settingsStore.settings?.appearance else { return }
        if LocalPrefs.accentColor == nil && !appearance.accentColor.isEmpty {
            setAccent(appearance.accentColor)
        }
        if LocalPrefs.themeMode == nil {
            setTheme(appearance.themeMode)
        }
    }

    private static func resolveAccent(local: String?, settings: AppSettings?) -> String {
        let fallback = "#2F6FED"
        let accent = local ?? settings?.appearance.accentColor ?? fallback
        return accent.isEmpty ? fallback : accent
    }
}
