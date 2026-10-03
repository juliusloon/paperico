import SwiftUI

/// A single dependency graph for every workspace destination.
struct AppEnvironment: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .environment(model)
            .environment(model.appStore)
            .environment(model.settingsStore)
            .environment(model.projectsStore)
            .environment(model.papersStore)
            .environment(model.readerStore)
            .environment(model.chatStore)
            .environment(model.router)
            .environment(model.services)
            .environment(\.palette, model.palette)
            .environment(\.backgroundOpacity, model.appStore.backgroundOpacity)
            .environment(\.glassOpacity, model.appStore.glassOpacity)
            .preferredColorScheme(model.preferredScheme)
            .tint(model.palette.accent)
    }
}
