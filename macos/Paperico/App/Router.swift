import SwiftUI

/// Mirrors react-router routes: /, /library, /paper/:id, /settings, /methods.
@MainActor
@Observable
final class Router {
    enum Page: Hashable {
        case home
        case library
        case methods
        case settings
        case reader(paperId: String)
    }

    var page: Page = .home

    @ObservationIgnored var navigationGuard: ((Page) -> Bool)?
    func go(_ page: Page) {
        guard navigationGuard?(page) ?? true else { return }
        self.page = page
    }
    func goWithoutGuard(_ page: Page) { self.page = page }

    /// WorkspaceNav offers a shortcut to the last opened paper (paperico:last-paper).
    var lastPaperId: String? {
        get { LocalPrefs.lastPaperId }
        set { LocalPrefs.lastPaperId = newValue }
    }
}
