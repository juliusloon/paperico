import SwiftUI
import PDFKit
#if os(iOS)
import UIKit
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformColor = NSColor
#endif

/// Native PDFKit replacement for reader/PdfReadingArea.tsx (pdf.js canvas stack).
/// Continuous single-page scrolling, zoom memory per paper, within-page progress,
/// native text selection with an "引用选中内容" attach action.
struct PdfReadingArea: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore

    let paperId: String
    let layout: LibraryLayout
    @Binding var zoom: Double
    @Binding var progress: Double
    var onAttachSelection: (String) -> Void

    @State private var shared = SharedPdfState()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlatformPdfView(
                paperId: paperId,
                layout: layout,
                backgroundColor: .clear,
                dark: palette.dark,
                zoom: zoom,
                shared: shared,
                onZoomChange: { next in
                    guard abs(zoom - next) > 0.001 else { return }
                    zoom = next
                    LocalPrefs.setPdfZoom(next, paperId: paperId)
                },
                onProgressChange: { next in
                    if abs(progress - next) >= 0.05 {
                        progress = next
                        LocalPrefs.setPdfProgress(next, paperId: paperId)
                    }
                }
            )
            .ignoresSafeArea(edges: .bottom)

            if shared.failed {
                VStack(spacing: 10) {
                    Image.ic(Ic.alertTriangle).font(.system(size: 20)).foregroundStyle(palette.accent)
                    Text("无法打开原始 PDF").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.gray800)
                    Text("未找到本地 PDF，请检查论文文件是否仍在数据目录中。")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.gray500)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            }
        }
        .overlay {
            GeometryReader { geometry in
                if let rect = shared.selectionRect, let text = shared.selectionText, !text.isEmpty {
                    SelectionActionOverlay(selectionRect: rect, viewport: geometry.size) {
                        let snippet = "P\(shared.selectionPage ?? 1) · \(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6000)))"
                        onAttachSelection(snippet)
                        shared.clearSelection()
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if !shared.loaded && !shared.failed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在载入原始 PDF…").font(.system(size: 12)).foregroundStyle(palette.gray500)
                }
                .padding(.top, 20)
            }
        }
        .onAppear { shared.focusColor = PlatformColor(palette.accent) }
        .onChange(of: palette.accent) { _, accent in
            shared.focusColor = PlatformColor(accent)
        }
        .onChange(of: readerStore.pendingPdfFocus) { _, pending in
            // T2.3: jump to the block's page and flash its bbox for 1.8s.
            guard let pending else { return }
            if let block = readerStore.paper?.blocks.first(where: { $0.id == pending.blockId }) {
                shared.focusBlock = block
                shared.focusToken = pending.token
            }
            readerStore.pendingPdfFocus = nil
        }
    }

}

/// Selection + load state shared between the PDFKit coordinator and SwiftUI.
@MainActor
@Observable
final class SharedPdfState {
    var selectionText: String?
    var selectionPage: Int?
    var selectionRect: CGRect?
    var isSelecting = false
    @ObservationIgnored weak var pdfView: PDFView?
    func clearSelection() {
        pdfView?.currentSelection = nil
        selectionText = nil
        selectionRect = nil
    }
    var loaded = false
    var failed = false
    // T2.3 focus request; the coordinator applies it once the document is ready.
    var focusBlock: Block?
    var focusToken = 0
    var focusColor: PlatformColor?
}

// MARK: - Shared coordinator logic

@MainActor
final class PdfCoordinatorBase: NSObject, PDFViewDelegate {
    weak var pdfView: PDFView?
    var loadedPaperId: String?

    private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private var selectionMonitor: Any?
    private weak var selectionWindow: NSWindow?
    private var savedBackgroundDragging = false
    #endif
    private var shared: SharedPdfState?
    private var onProgressChange: ((Double) -> Void)?
    private var onZoomChange: ((Double) -> Void)?
    private var currentZoom: Double = 1
    private var lastAppliedZoom: Double = 0
    private var baseFitFactor: CGFloat = 0
    private var lastFocusToken = 0
    private var restoringProgress = false
    private var progressScheduled = false

    func attach(_ view: PDFView, shared: SharedPdfState, onZoomChange: @escaping (Double) -> Void,
                onProgressChange: @escaping (Double) -> Void) {
        detach()
        self.pdfView = view
        self.shared = shared
        shared.pdfView = view
        self.onProgressChange = onProgressChange
        self.onZoomChange = onZoomChange

        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.scheduleProgress() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged, object: view, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reportSelection() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [weak self] _ in Task { @MainActor in
            self?.reportZoom()
            self?.reportSelection()
            self?.scheduleProgress()
        } })
        #if os(macOS)
        selectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, let pdfView = self.pdfView else { return event }
            if event.type == .leftMouseDown, event.window === pdfView.window {
                let point = pdfView.convert(event.locationInWindow, from: nil)
                // Only PDFKit content starts a selection; overlays keep their existing selection.
                if let content = pdfView.window?.contentView,
                   let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                   hit.isDescendant(of: pdfView), pdfView.bounds.contains(point) {
                    self.selectionGestureChanged(active: true)
                }
            } else if event.type == .leftMouseUp,
                      event.window === pdfView.window || self.shared?.isSelecting == true {
                self.selectionGestureChanged(active: false)
                // PDFKit receives the mouse-up after this local monitor.
                DispatchQueue.main.async { [weak self] in self?.reportSelection() }
            }
            return event
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in
            self?.selectionGestureChanged(active: false)
            self?.shared?.clearSelection()
        } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let changed = notification.object as? NSView else { return }
            Task { @MainActor in
                guard let self, let pdfView = self.pdfView, changed.isDescendant(of: pdfView) else { return }
                self.reportSelection()
                self.scheduleProgress()
            }
        })
        #endif
    }

    func viewportChanged() {
        guard let pdfView, pdfView.document != nil else { return }
        baseFitFactor = pdfView.scaleFactorForSizeToFit
        applyZoom()
        reportSelection()
        scheduleProgress()
    }

    func loadPaperIfNeeded(paperId: String, layout: LibraryLayout) {
        guard loadedPaperId != paperId else { return }
        loadedPaperId = paperId
        shared?.loaded = false
        shared?.failed = false
        shared?.clearSelection()
        restoringProgress = true
        let url = layout.pdfURL(paperId)
        Task { @MainActor [weak self] in
            let document = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url)
            }.value
            guard let self, let pdfView = self.pdfView, self.loadedPaperId == paperId else { return }
            if let document {
                pdfView.document = document
                self.shared?.loaded = true
                self.shared?.failed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.baseFitFactor = pdfView.scaleFactorForSizeToFit
                    self?.applyZoom()
                    self?.restoreProgress()
                    self?.restoringProgress = false
                    self?.scheduleProgress()
                    self?.processPendingFocus()
                }
            } else {
                self.shared?.loaded = false
                self.shared?.failed = true
            }
        }
    }

    func updateZoom(_ zoom: Double) {
        currentZoom = zoom
        guard pdfView?.document != nil, abs(lastAppliedZoom - zoom) > 0.001 else { return }
        applyZoom()
    }

    private func applyZoom() {
        guard let pdfView else { return }
        let fit = baseFitFactor > 0 ? baseFitFactor : pdfView.scaleFactorForSizeToFit
        guard fit > 0 else { return }
        baseFitFactor = fit
        lastAppliedZoom = currentZoom
        pdfView.minScaleFactor = fit * 0.6
        pdfView.maxScaleFactor = fit * 2.4
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, fit * CGFloat(currentZoom)))
    }

    /// PDFKit owns pinch magnification. Keep the binding and saved zoom in the
    /// same fit-relative units as the toolbar, without reapplying the gesture.
    private func reportZoom() {
        guard let pdfView, pdfView.document != nil, baseFitFactor > 0 else { return }
        let zoom = Double(pdfView.scaleFactor / baseFitFactor)
        guard zoom.isFinite, abs(currentZoom - zoom) > 0.001 else { return }
        currentZoom = zoom
        lastAppliedZoom = zoom
        onZoomChange?(zoom)
    }

    private func restoreProgress() {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let stored = LocalPrefs.pdfProgress(paperId: loadedPaperId ?? "")
        guard stored > 0 else { return }
        let position = PDFReadingPosition(progress: stored, pageCount: document.pageCount)
        if let page = document.page(at: position.pageIndex) {
            let bounds = page.bounds(for: pdfView.displayBox)
            let point = CGPoint(x: bounds.minX, y: bounds.maxY - bounds.height * position.fraction)
            pdfView.go(to: PDFDestination(page: page, at: point))
        }
    }

    /// T2.3: apply a pending block focus — jump to its page and flash the
    /// bbox as a temporary annotation for 1.8s. Without a usable bbox or
    /// page_idx only the page jump happens (docs/bbox-coordinate-system.md).
    func processPendingFocus() {
        guard let shared, let pdfView, let block = shared.focusBlock,
              shared.focusToken != lastFocusToken else { return }
        guard let document = pdfView.document, document.pageCount > 0 else { return } // retried after load
        lastFocusToken = shared.focusToken
        guard let pageIdx = block.pageIdx, pageIdx >= 0, pageIdx < document.pageCount,
              let page = document.page(at: pageIdx) else { return }
        pdfView.go(to: page)
        guard let bbox = block.bbox, bbox.count == 4,
              bbox.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return }
        // PDFKit's origin is bottom-left with y pointing up; the MinerU bbox
        // is page-relative with y pointing down — flip vertically.
        let rect = CGRect(
            x: bounds.width * CGFloat(bbox[0] / 1000),
            y: bounds.height * CGFloat(1 - bbox[3] / 1000),
            width: bounds.width * CGFloat((bbox[2] - bbox[0]) / 1000),
            height: bounds.height * CGFloat((bbox[3] - bbox[1]) / 1000)
        )
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.color = PlatformColor.clear // transparent border, accent fill at ~30%
        #if os(iOS)
        let focus = shared.focusColor ?? UIColor.systemBlue
        #else
        let focus = shared.focusColor ?? NSColor.controlAccentColor
        #endif
        annotation.setValue(focus.withAlphaComponent(0.3), forAnnotationKey: .interiorColor)
        page.addAnnotation(annotation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak page, weak annotation] in
            if let annotation { page?.removeAnnotation(annotation) }
        }
    }

    private func scheduleProgress() {
        guard !restoringProgress, !progressScheduled else { return }
        progressScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.progressScheduled = false
            self.reportProgress()
        }
    }

    private func reportProgress() {
        guard !restoringProgress, let pdfView, let document = pdfView.document,
              document.pageCount > 0, pdfView.bounds.height > 0 else { return }
        #if os(macOS)
        let flipped = pdfView.isFlipped
        #else
        let flipped = true
        #endif
        let viewport = pdfView.bounds
        let top = flipped ? viewport.minY : viewport.maxY
        let anchor = CGPoint(x: viewport.midX, y: top)
        guard let page = pdfView.page(for: anchor, nearest: true) else { return }
        let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        guard rect.height > 0 else { return }
        let fraction = flipped ? (top - rect.minY) / rect.height : (rect.maxY - top) / rect.height
        let position = PDFReadingPosition(pageIndex: document.index(for: page), fraction: Double(fraction))
        var next = position.percentage(pageCount: document.pageCount)
        if let last = document.page(at: document.pageCount - 1) {
            let lastRect = pdfView.convert(last.bounds(for: pdfView.displayBox), from: last)
            let bottomVisible = flipped ? lastRect.maxY <= viewport.maxY + 1 : lastRect.minY >= viewport.minY - 1
            if bottomVisible { next = 100 }
        }
        onProgressChange?(next)
    }

    /// Mouse-down hides the action immediately. Keyboard selections can publish normally.
    func selectionGestureChanged(active: Bool) {
        #if os(macOS)
        // PDFKit hits private page/scroll views. Disable background dragging
        // before AppKit dispatches mouseDown to them, then restore it on release.
        if active, selectionWindow == nil, let window = pdfView?.window {
            selectionWindow = window
            savedBackgroundDragging = window.isMovableByWindowBackground
            window.isMovableByWindowBackground = false
        } else if !active, let window = selectionWindow {
            window.isMovableByWindowBackground = savedBackgroundDragging
            selectionWindow = nil
        }
        #endif
        shared?.isSelecting = active
        if active { shared?.selectionRect = nil }
    }

    func detach() {
        selectionGestureChanged(active: false)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        #if os(macOS)
        if let selectionMonitor { NSEvent.removeMonitor(selectionMonitor) }
        selectionMonitor = nil
        #endif
        shared?.isSelecting = false
        shared?.selectionRect = nil
        shared?.pdfView = nil
        shared = nil
        pdfView = nil
        loadedPaperId = nil
        baseFitFactor = 0
        lastAppliedZoom = 0
        lastFocusToken = 0
        restoringProgress = false
        progressScheduled = false
    }

    func reportSelection() {
        guard let pdfView, shared?.isSelecting != true else { return }
        #if os(macOS)
        // PDFKit may track the drag through a child view. Suppress notifications
        // while the actual mouse button is held even if hosting hit-testing differed.
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            shared?.selectionRect = nil
            return
        }
        #endif
        let selection = pdfView.currentSelection
        let text = selection?.string
        shared?.selectionRect = nil
        shared?.selectionText = (text?.isEmpty == false) ? text : nil
        if let selection, let page = selection.pages.first, let document = pdfView.document {
            shared?.selectionPage = document.index(for: page) + 1
            // Use the last visible line, rather than the union of whole pages.
            for line in selection.selectionsByLine().reversed() {
                for selectedPage in line.pages.reversed() {
                    let converted = pdfView.convert(line.bounds(for: selectedPage), from: selectedPage)
                    let visible = converted.intersection(pdfView.bounds)
                    guard !visible.isNull, visible.width > 0, visible.height > 0 else { continue }
                    #if os(macOS)
                    let y = pdfView.isFlipped ? visible.minY - pdfView.bounds.minY : pdfView.bounds.maxY - visible.maxY
                    #else
                    let y = visible.minY - pdfView.bounds.minY
                    #endif
                    guard y + visible.height > 76 else { continue }
                    shared?.selectionRect = CGRect(x: visible.minX - pdfView.bounds.minX, y: max(76, y),
                                                   width: visible.width, height: visible.height - max(0, 76 - y))
                    shared?.selectionPage = document.index(for: selectedPage) + 1
                    return
                }
            }
        } else {
            shared?.selectionPage = nil
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - Platform representables

#if os(iOS)
struct PlatformPdfView: UIViewRepresentable {
    let paperId: String
    let layout: LibraryLayout
    let backgroundColor: PlatformColor
    let dark: Bool
    let zoom: Double
    let shared: SharedPdfState
    let onZoomChange: (Double) -> Void
    let onProgressChange: (Double) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.pageShadowsEnabled = true
        view.backgroundColor = backgroundColor
        context.coordinator.attach(view, shared: shared, onZoomChange: onZoomChange, onProgressChange: onProgressChange)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.backgroundColor = backgroundColor
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        context.coordinator.updateZoom(zoom)
        context.coordinator.loadPaperIfNeeded(paperId: paperId, layout: layout)
        context.coordinator.processPendingFocus()
    }

    func makeCoordinator() -> PdfCoordinatorBase { PdfCoordinatorBase() }

    static func dismantleUIView(_ view: PDFView, coordinator: PdfCoordinatorBase) { coordinator.detach() }
}
#else
struct PlatformPdfView: NSViewRepresentable {
    let paperId: String
    let layout: LibraryLayout
    let backgroundColor: PlatformColor
    let dark: Bool
    let zoom: Double
    let shared: SharedPdfState
    let onZoomChange: (Double) -> Void
    let onProgressChange: (Double) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = TrackingPdfView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.pageShadowsEnabled = true
        view.backgroundColor = backgroundColor
        view.onViewportChange = { [weak coordinator = context.coordinator] in coordinator?.viewportChanged() }
        context.coordinator.attach(view, shared: shared, onZoomChange: onZoomChange, onProgressChange: onProgressChange)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        view.backgroundColor = backgroundColor
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        context.coordinator.updateZoom(zoom)
        context.coordinator.loadPaperIfNeeded(paperId: paperId, layout: layout)
        context.coordinator.processPendingFocus()
    }

    func makeCoordinator() -> PdfCoordinatorBase { PdfCoordinatorBase() }

    static func dismantleNSView(_ view: PDFView, coordinator: PdfCoordinatorBase) {
        (view as? TrackingPdfView)?.onViewportChange = nil
        coordinator.detach()
    }
}

private final class TrackingPdfView: PDFView {
    override var mouseDownCanMoveWindow: Bool { false }
    var onViewportChange: (() -> Void)?
    private var lastViewportSize: CGSize = .zero
    override func layout() {
        super.layout()
        // PDFKit's scroll canvas otherwise restores an opaque system fill even
        // when PDFView.backgroundColor is clear. Pages retain their own colors.
        clearScrollCanvas()
        guard bounds.size != lastViewportSize else { return }
        lastViewportSize = bounds.size
        DispatchQueue.main.async { [weak self] in self?.onViewportChange?() }
    }

    private func clearScrollCanvas() {
        clearScrollBackgrounds(in: self)
    }

    private func clearScrollBackgrounds(in view: NSView) {
        if let scroll = view as? NSScrollView {
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.contentView.drawsBackground = false
            scroll.contentView.backgroundColor = .clear
            return // Do not walk PDFKit's individual page views.
        }
        view.subviews.forEach { clearScrollBackgrounds(in: $0) }
    }
}
#endif
