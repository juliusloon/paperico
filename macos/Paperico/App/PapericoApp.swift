import SwiftUI

@main
struct PapericoApp: App {
    @NSApplicationDelegateAdaptor(PapericoAppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        Window("Paperico", id: "workspace") {
            RootView()
                .modifier(AppEnvironment(model: appModel))
                #if os(macOS)
                .frame(minWidth: 490, minHeight: 560)
                #endif
        }
        #if os(macOS)
        // 去掉系统标题栏:红绿灯悬浮于窗口左上角,由左侧栏顶部承接
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1360, height: 860)
        .commands {
            WorkspaceSettingsCommands(router: appModel.router)
            ReaderAnnotationCommands()
            CommandMenu("工作台") {
                Button("首页") { appModel.router.go(.home) }.keyboardShortcut("1")
                Button("论文库") { appModel.router.go(.library) }.keyboardShortcut("2")
                Button("方法索引") { appModel.router.go(.methods) }.keyboardShortcut("3")
            }
        }
        #endif
    }
}

#if os(macOS)
private struct ReaderAnnotationStoreKey: FocusedValueKey { typealias Value = ReaderStore }
extension FocusedValues {
    var readerAnnotationStore: ReaderStore? {
        get { self[ReaderAnnotationStoreKey.self] }
        set { self[ReaderAnnotationStoreKey.self] = newValue }
    }
}

/// Text editors keep their own undo stack; completed node edits share the paper draft.
private struct ReaderAnnotationCommands: Commands {
    @FocusedValue(\.readerAnnotationStore) private var readerStore
    private var textEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView || readerStore?.editingAnnotation == true
    }
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") {
                if let readerStore, !textEditing { readerStore.annotationDraft.undo() }
                else { NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil) }
            }.keyboardShortcut("z", modifiers: .command)
                .disabled(textEditing ? false : !(readerStore?.annotationDraft.canUndo ?? NSApp.keyWindow?.firstResponder?.undoManager?.canUndo ?? false))
            Button("重做") {
                if let readerStore, !textEditing { readerStore.annotationDraft.redo() }
                else { NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil) }
            }.keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(textEditing ? false : !(readerStore?.annotationDraft.canRedo ?? NSApp.keyWindow?.firstResponder?.undoManager?.canRedo ?? false))
        }
        CommandGroup(after: .newItem) {
            Button("保存逻辑链与节点笔记") { Task { _ = await readerStore?.saveAnnotations() } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(readerStore == nil || readerStore?.hasUnsavedAnnotations != true || readerStore?.savingAnnotations == true)
        }
    }
}

/// The menu and shortcut share the existing workspace destination.
private struct WorkspaceSettingsCommands: Commands {
    let router: Router
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                router.go(.settings)
                openWindow(id: "workspace")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
