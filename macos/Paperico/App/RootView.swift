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
            // 红绿灯留白:单一来源,页面用 trafficLightTopPadding() 消费。
            .environment(\.trafficLightClearance, topClearance)
            .animation(.easeInOut(duration: 0.18), value: router.page)
        }
        .background(palette.appBase)
        .task { appModel.onAppear() }
        .onAppear {
            AppBootstrap.install()
            applyWindowChrome()
        }
        // 主题切换时同步刷新窗口背景,避免深色模式下出现系统灰色的窗口底色接缝。
        .onChange(of: palette.appBase) { _, _ in applyWindowChrome() }
    }

    private var topClearance: CGFloat {
        #if os(macOS)
        WindowChrome.additionalTopClearance
        #else
        0
        #endif
    }

    private func applyWindowChrome() {
        #if os(macOS)
        WindowChrome.applyToAll(baseColor: NSColor(palette.appBase))
        #endif
    }
}
