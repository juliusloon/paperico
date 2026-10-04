import SwiftUI
import WebKit

/// A single offline document surface preserves the web reader's typography and
/// KaTeX layout. Native stores still own papers, navigation, chat and persistence.
struct PaperDocumentView: View {
    let detail: PaperDetail
    let annotations: [String: ReaderNodeAnnotation]
    let onAnnotation: (String, String, String, String) -> Void
    let onAnnotationFocus: (Bool) -> Void
    let layout: LibraryLayout
    let fontSize: CGFloat
    let mode: BilingualMode
    let outlineWidth: CGFloat
    let progress: Double
    let pendingTarget: String?
    let centered: Bool
    let onProgress: (Double, String) -> Void
    let onAttach: (AttachedContext) -> Void
    let onJump: (String) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.glassOpacity) private var glassOpacity
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var selectionState = DocumentSelectionState()

    var body: some View {
        GeometryReader { geometry in
            PaperWebSurface(document: self, selectionState: selectionState)
                .overlay {
                    if let selection = selectionState.selection {
                        SelectionActionOverlay(selectionRect: selection.rect, viewport: geometry.size) {
                            onAttach(AttachedContext(type: "text_selection", refBlockId: selection.blockId,
                                                     refEntityId: nil, snippet: selection.snippet))
                            selectionState.clear()
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let editor = selectionState.annotationEditor {
                        ReaderAnnotationEditor(field: editor.field, value: editor.value, size: editor.rect.size) {
                            selectionState.input(editor, value: $0)
                        } onFinish: { value, commit in
                            selectionState.input(editor, value: value, phase: commit ? "commit" : "cancel")
                        } onResize: { size in
                            selectionState.resize(editor, size: size)
                        }
                        .id(editor.blockId + ":" + editor.field)
                        .offset(x: editor.rect.minX, y: editor.rect.minY)
                    }
                }
                .clipped()
        }
    }

    fileprivate var style: [String: Any] {
        var colors: [String: String] = [:]
        let tokens: [(String, Color)] = [
            ("gray-0",palette.gray0),("gray-50",palette.gray50),("gray-100",palette.gray100),
            ("gray-200",palette.gray200),("gray-300",palette.gray300),("gray-400",palette.gray400),
            ("gray-500",palette.gray500),("gray-600",palette.gray600),("gray-700",palette.gray700),("gray-800",palette.gray800),
            ("gray-900",palette.gray900),("accent",palette.accent),("accent-foreground",palette.accentForeground),("accent-soft",palette.accentSoft),
            ("accent-faint",palette.accentFaint),("inset-surface",palette.insetSurface)
        ]
        for (key, color) in tokens {
            if let c = NSColor(color).usingColorSpace(.sRGB) {
                colors[key] = String(format: "rgba(%d,%d,%d,%.4f)", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), c.alphaComponent)
            }
        }
        return ["colors":colors,"fontSize":Double(fontSize),"mode":mode.rawValue,
                "outlineWidth":Double(outlineWidth),"compact":false,"dark":palette.dark,
                "insetRadius":Double(CornerRadius.inset),"nativeAnnotations":true,
                "glassOpacity":reduceTransparency ? 1 : min(1, max(0, glassOpacity)),
                "reduceTransparency":reduceTransparency]
    }

}

private struct DocumentSelection {
    let blockId: String?
    let snippet: String
    let rect: CGRect
}

private struct DocumentAnnotationEditor {
    let blockId: String
    let field: String
    let value: String
    let rect: CGRect
}

@MainActor @Observable
private final class DocumentSelectionState {
    var selection: DocumentSelection?
    var annotationEditor: DocumentAnnotationEditor?
    @ObservationIgnored weak var webView: WKWebView?
    func clear() {
        selection = nil
        webView?.evaluateJavaScript("window.papericoClearSelection()")
    }
    func input(_ editor: DocumentAnnotationEditor, value: String, phase: String = "draft") {
        webView?.callAsyncJavaScript("window.papericoAnnotationInput?.(id,field,value,phase)",
                                    arguments: ["id":editor.blockId,"field":editor.field,"value":value,"phase":phase], in: nil, in: .page)
    }
    func resize(_ editor: DocumentAnnotationEditor, size: CGSize) {
        webView?.callAsyncJavaScript("window.papericoResizeAnnotation?.(id,field,width,height)",
                                    arguments: ["id":editor.blockId,"field":editor.field,"width":size.width,"height":size.height], in: nil, in: .page)
    }
}

private struct PaperWebSurface: NSViewRepresentable {
    let document: PaperDocumentView
    let selectionState: DocumentSelectionState

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "reader")
        config.setURLSchemeHandler(context.coordinator.images, forURLScheme: "paperico-image")
        let view = AnnotationWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        // WebKit still paints its own canvas when CSS and the overscroll color
        // are clear on macOS. Keep this compatibility hook scoped to this view.
        // Guard the setter so an OS that removes it retains a usable reader.
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            view.setValue(false, forKey: "drawsBackground")
        }
        view.underPageBackgroundColor = .clear
        context.coordinator.webView = view
        selectionState.webView = view
        let resource = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Resources/Reader")
        if let resource {
            view.loadFileURL(resource, allowingReadAccessTo: resource.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        view.underPageBackgroundColor = .clear
        context.coordinator.update()
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.parent.selectionState.annotationEditor = nil
        coordinator.parent.document.onAnnotationFocus(false)
        view.configuration.userContentController.removeScriptMessageHandler(forName: "reader")
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PaperWebSurface
        weak var webView: WKWebView?
        let images = PaperImageSchemeHandler()
        private var ready = false
        private var documentReady = false
        private var loadedDetail: PaperDetail?
        private var lastStyle: NSDictionary?
        private var lastAnnotations: NSDictionary?
        private var lastTarget: String?
        private var applyingStyle = false
        private var queuedStyle: [String: Any]?

        init(_ parent: PaperWebSurface) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            update()
        }

        func update() {
            guard ready, let webView else { return }
            if loadedDetail != parent.document.detail {
                parent.selectionState.annotationEditor = nil
                documentReady = false
                images.urls = Dictionary(uniqueKeysWithValues: parent.document.detail.blocks.compactMap { block in
                    guard !block.imagePath.isEmpty, let url = parent.document.layout.fileURL(forRelativePath: block.imagePath) else { return nil }
                    return (block.id, url)
                })
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                guard let data = try? encoder.encode(parent.document.detail),
                      var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                payload["annotations"] = annotationPayload()
                payload["progress"] = parent.document.progress
                payload["excluded_block_ids"] = zip(parent.document.detail.blocks, PaperContentScope.regions(parent.document.detail.blocks))
                    .filter { $0.1 != .body }.map { $0.0.id }
                if let outlines = try? encoder.encode(PaperOutline.entries(parent.document.detail.blocks)),
                   let values = try? JSONSerialization.jsonObject(with: outlines) {
                    payload["outline_entries"] = values
                }
                loadedDetail = parent.document.detail
                lastTarget = nil
                webView.callAsyncJavaScript("window.papericoLoad(payload)", arguments: ["payload":payload], in: nil, in: .page) { [weak self] _ in
                    self?.applyPendingJump()
                }
            }
            let annotations = annotationPayload()
            if lastAnnotations != annotations as NSDictionary {
                lastAnnotations = annotations as NSDictionary
                webView.callAsyncJavaScript("window.papericoAnnotations(values)", arguments: ["values": annotations], in: nil, in: .page)
            }
            let style = parent.document.style
            if lastStyle != style as NSDictionary {
                lastStyle = style as NSDictionary
                queuedStyle = style
                applyStyle()
            }
            applyPendingJump()
        }

        private func annotationPayload() -> [String: Any] {
            guard let data = try? JSONEncoder().encode(parent.document.annotations),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return payload
        }

        // Coalesce rapid layout updates rather than queuing a JS call for every
        // pointer event. The native splitter itself never animates while dragging.
        private func applyStyle() {
            guard !applyingStyle, let style = queuedStyle, let webView else { return }
            queuedStyle = nil
            applyingStyle = true
            webView.callAsyncJavaScript("window.papericoStyle(style)", arguments: ["style":style], in: nil, in: .page) { [weak self] _ in
                guard let self else { return }
                self.applyingStyle = false
                self.applyStyle()
            }
        }

        private func applyPendingJump() {
            guard documentReady else { return }
            guard let target = parent.document.pendingTarget else { lastTarget = nil; return }
            guard target != lastTarget, let webView else { return }
            lastTarget = target
            webView.callAsyncJavaScript("window.papericoJump(id,centered)", arguments: ["id":target,"centered":parent.document.centered], in: nil, in: .page)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let data = message.body as? [String: Any], data["paperId"] as? String == parent.document.detail.paper.id,
                  let type = data["type"] as? String else { return }
            let blockId = data["blockId"] as? String
            let block = parent.document.detail.blocks.first { $0.id == blockId }
            switch type {
            case "annotationEditor":
                guard data["active"] as? Bool == true else {
                    parent.selectionState.annotationEditor = nil
                    return
                }
                guard let blockId, block != nil,
                      let field = data["field"] as? String, ["title", "note"].contains(field),
                      let values = data["rect"] as? [String: Double],
                      let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"],
                      [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height >= 64 else { return }
                parent.selectionState.selection = nil
                parent.selectionState.annotationEditor = DocumentAnnotationEditor(blockId: blockId, field: field,
                    value: data["value"] as? String ?? "", rect: CGRect(x: x, y: y, width: width, height: height))
            case "annotationFocus":
                (webView as? AnnotationWebView)?.editingNodeNote = data["note"] as? Bool ?? false
                parent.document.onAnnotationFocus(data["editing"] as? Bool ?? false)
            case "annotation":
                guard let blockId, block != nil, let phase = data["phase"] as? String,
                      ["draft", "commit", "cancel"].contains(phase) else { return }
                parent.document.onAnnotation(blockId, data["field"] as? String ?? "", data["value"] as? String ?? "", phase)
            case "loaded":
                documentReady = true
                applyPendingJump()
            case "progress":
                if let value = data["progress"] as? Double { parent.document.onProgress(value,blockId ?? "") }
            case "jump":
                if let blockId, block != nil { parent.document.onJump(blockId) }
            case "selectionChanged":
                guard let snippet = data["snippet"] as? String, !snippet.isEmpty,
                      let values = data["rect"] as? [String: Double],
                      let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"],
                      [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else {
                    parent.selectionState.selection = nil
                    return
                }
                parent.selectionState.selection = DocumentSelection(blockId: block?.id, snippet: String(snippet.prefix(6000)),
                                                                    rect: CGRect(x: x, y: y, width: width, height: height))
            case "selection":
                guard let snippet = data["snippet"] as? String, !snippet.isEmpty else { return }
                parent.document.onAttach(AttachedContext(type: "text_selection",refBlockId: block?.id,refEntityId: nil,snippet: String(snippet.prefix(6000))))
            case "figure":
                guard let block else { return }
                parent.document.onAttach(AttachedContext(type: "figure",refBlockId: block.id,refEntityId: nil,snippet: nil))
            case "entity":
                guard let id = data["id"] as? String, let entity = parent.document.detail.entities.first(where: { $0.id == id }) else { return }
                parent.document.onAttach(AttachedContext(type: "method_card",refBlockId: block?.id,refEntityId: id,snippet: entity.name))
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if ["https","http","mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
            } else {
                decisionHandler(url.isFileURL ? .allow : .cancel)
            }
        }
    }
}

@MainActor private final class AnnotationWebView: WKWebView {
    var editingNodeNote = false
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editingNodeNote, event.modifierFlags.intersection([.command, .control, .option]) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased(), ["b", "i", "h"].contains(key) {
            callAsyncJavaScript("window.papericoFormatNodeNote?.(key)", arguments: ["key": key], in: nil, in: .page)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Exposes only this paper's validated local image URLs to the document; it
/// cannot read arbitrary paths or fetch remote images supplied by Markdown.
@MainActor
final class PaperImageSchemeHandler: NSObject, WKURLSchemeHandler {
    var urls: [String: URL] = [:]
    private var active: [ObjectIdentifier: WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let request = task.request.url, request.host == "block",
              let url = urls[String(request.path.dropFirst()).removingPercentEncoding ?? ""] else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let id = ObjectIdentifier(task)
        active[id] = task
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Data(contentsOf: url) }
            DispatchQueue.main.async {
                guard let self, let task = self.active.removeValue(forKey: id) else { return }
                switch result {
                case .success(let data):
                    let mime = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                    task.didReceive(URLResponse(url: request,mimeType: mime,expectedContentLength: data.count,textEncodingName: nil))
                    task.didReceive(data)
                    task.didFinish()
                case .failure(let error): task.didFailWithError(error)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(task))
    }
}
