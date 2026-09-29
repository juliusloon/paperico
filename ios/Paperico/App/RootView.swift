import SwiftUI

/// Root layout (mirrors App.tsx): routed pages;每页自带工作台导航
/// (常规宽度贴底左侧,紧凑宽度顶部导航条)。
struct RootView: View {
    @Environment(\.palette) private var palette
    @Environment(AppModel.self) private var appModel
    @Environment(Router.self) private var router

    var body: some View {
        GeometryReader { geo in
            Group {
                switch router.page {
                case .home:
                    HomePage()
                case .library:
                    LibraryPage()
                case .methods:
                    MethodsPage()
                case .settings:
                    SettingsPage()
                case .reader(let paperId):
                    ReaderPage(paperId: paperId)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .environment(\.containerWidth, geo.size.width)
            .animation(.easeInOut(duration: 0.18), value: router.page)
        }
        .background(palette.appBase)
        .task { appModel.onAppear() }
        .onAppear {
            // 隐藏标题栏后仍可拖动窗口空白处移动(红绿灯仍可点击)
            #if os(macOS)
            for window in NSApp.windows where window.isVisible {
                window.isMovableByWindowBackground = true
            }
            #endif
        }
    }
}
