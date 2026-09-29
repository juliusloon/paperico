import SwiftUI

/// Root layout (mirrors App.tsx): floating nav pill + routed pages.
struct RootView: View {
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(AppModel.self) private var appModel
    @Environment(Router.self) private var router

    var body: some View {
        Group {
            switch router.page {
            case .home:
                VStack(spacing: 0) {
                    HomeNavSlot()
                    HomePage()
                }
                .background(palette.appBase)
            case .library:
                LibraryPage().floatingNavOverlay()
            case .methods:
                MethodsPage().floatingNavOverlay()
            case .settings:
                SettingsPage().floatingNavOverlay()
            case .reader(let paperId):
                ReaderPage(paperId: paperId)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.appBase)
        .animation(.easeInOut(duration: 0.18), value: router.page)
        .task { appModel.onAppear() }
    }
}

/// Workspace pages keep the nav pill floating over the content area on regular width;
/// compact widths embed their own top bar, so no floating pill there.
extension View {
    @ViewBuilder
    func floatingNavOverlay() -> some View {
        FloatingNavOverlay()
    }
}

private struct FloatingNavOverlay: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if sizeClass == .regular {
                WorkspaceNav()
                    .padding(.leading, 14)
                    .padding(.top, 14)
            }
        }
    }
}
