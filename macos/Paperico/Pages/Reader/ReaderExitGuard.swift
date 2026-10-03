import SwiftUI
import AppKit

/// Navigation, close and quit all share one decision while edits are still staged.
struct ReaderExitGuard: ViewModifier {
    @Environment(ReaderStore.self) private var readerStore
    @Environment(Router.self) private var router
    @State private var presentsPrompt = false
    @State private var pendingExit: (() -> Void)?
    @State private var cancelExit: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .background { ReaderWindowCloseBridge(shouldClose: shouldClose) }
            .alert("保存逻辑链与节点笔记的编辑？", isPresented: $presentsPrompt) {
                Button("继续编辑", role: .cancel) { cancelExit?(); clearPending() }
                Button("放弃编辑", role: .destructive) {
                    readerStore.discardAnnotations()
                    finishExit()
                }
                Button("保存并退出") {
                    Task {
                        if await readerStore.saveAnnotations() { finishExit() }
                        else { presentsPrompt = true }
                    }
                }
            } message: {
                Text(readerStore.annotationsError.isEmpty ? "尚有未保存的逻辑链或节点笔记。保存后，下次打开这篇论文仍可查看。" : readerStore.annotationsError)
            }
            .onAppear {
                router.navigationGuard = { destination in
                    guard destination != router.page, readerStore.hasUnsavedAnnotations else { return true }
                    pendingExit = { router.goWithoutGuard(destination) }
                    cancelExit = nil; presentsPrompt = true
                    return false
                }
                PapericoAppDelegate.quitDecision = {
                    guard readerStore.hasUnsavedAnnotations else { return .terminateNow }
                    pendingExit = { NSApp.reply(toApplicationShouldTerminate: true) }
                    cancelExit = { NSApp.reply(toApplicationShouldTerminate: false) }
                    presentsPrompt = true
                    return .terminateLater
                }
            }
    }
    private func shouldClose(_ window: NSWindow) -> Bool {
        guard readerStore.hasUnsavedAnnotations else { return true }
        pendingExit = { [weak window] in window?.performClose(nil) }
        cancelExit = nil; presentsPrompt = true
        return false
    }
    private func clearPending() { pendingExit = nil; cancelExit = nil }
    private func finishExit() { let action = pendingExit; clearPending(); action?() }
}

@MainActor final class PapericoAppDelegate: NSObject, NSApplicationDelegate {
    static var quitDecision: (() -> NSApplication.TerminateReply)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.quitDecision?() ?? .terminateNow
    }
}

private struct ReaderWindowCloseBridge: NSViewRepresentable {
    let shouldClose: (NSWindow) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(shouldClose: shouldClose) }
    func makeNSView(context: Context) -> GuardView {
        let view = GuardView(); view.coordinator = context.coordinator; return view
    }
    func updateNSView(_ view: GuardView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        context.coordinator.attach(view.window)
    }
    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) { coordinator.detach() }
    final class GuardView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: (NSWindow) -> Bool
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        init(shouldClose: @escaping (NSWindow) -> Bool) { self.shouldClose = shouldClose }
        func attach(_ next: NSWindow?) {
            guard let next, next !== window else { return }
            detach(); window = next; original = next.delegate; next.delegate = self
        }
        func detach() { if window?.delegate === self { window?.delegate = original }; window = nil; original = nil }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            shouldClose(sender) && (original?.windowShouldClose?(sender) ?? true)
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
