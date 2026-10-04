import Foundation
import Observation

@MainActor @Observable
final class UpdateStore {
    private let defaults: UserDefaults
    private(set) var checking = false
    private(set) var available: AppRelease?
    private(set) var message = ""
    private(set) var failed = false
    var showPrompt = false
    var wantsUpdateSettings = false
    var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: "paperico:auto-check-updates") }
    }
    var lastChecked: Date? { defaults.object(forKey: "paperico:last-update-check") as? Date }
    let currentVersion: String

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
        automaticallyChecks = defaults.object(forKey: "paperico:auto-check-updates") as? Bool ?? true
    }

    func check(manual: Bool = false) async {
        guard !checking else { return }
        if !manual {
            guard automaticallyChecks else { return }
            let lastAttempt = defaults.object(forKey: "paperico:last-update-attempt") as? Date ?? .distantPast
            guard Date().timeIntervalSince(lastAttempt) >= 24 * 60 * 60 else { return }
        }
        checking = true
        failed = false
        message = "正在检查更新…"
        defaults.set(Date(), forKey: "paperico:last-update-attempt")
        defer { checking = false }
        do {
            available = try await AppRelease.fetch(currentVersion: currentVersion)
            defaults.set(Date(), forKey: "paperico:last-update-check")
            if let available {
                message = "发现新版本 \(available.versionLabel)"
                if manual || defaults.string(forKey: "paperico:dismissed-update") != available.tagName { showPrompt = true }
            } else { message = "当前已是最新正式版本。" }
        } catch {
            failed = true
            message = "检查更新失败：\(error.localizedDescription)"
            // Background failures remain in settings without interrupting reading.
        }
    }

    func dismissPrompt() {
        if let available { defaults.set(available.tagName, forKey: "paperico:dismissed-update") }
        showPrompt = false
    }
}
