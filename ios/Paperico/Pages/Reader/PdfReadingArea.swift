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
/// Continuous single-page scrolling, zoom memory per paper, page-based progress,
/// native text selection with an "引用选中内容" attach action.
struct PdfReadingArea: View {
    @Environment(\.palette) private var palette
    @Environment(ReaderStore.self) private var readerStore

    let paperId: String
    @Binding var zoom: Double
    @Binding var progress: Double
    var onAttachSelection: (String) -> Void

    @State private var shared = SharedPdfState()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlatformPdfView(
                paperId: paperId,
                zoom: zoom,
                shared: shared,
                onPageChange: { pageIndex, pageCount in
                    let next = pageCount > 0 ? Double(pageIndex + 1) / Double(pageCount) * 100 : 0
                    if abs(progress - next) >= 0.5 {
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
                    Text("请确认论文已解析完成,或后端服务可用。")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.gray500)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.gray0)
            } else {
                attachButton
                    .padding(.top, 62)
                    .padding(.trailing, 18)
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

    private var attachButton: some View {
        Button {
            if let text = shared.selectionText, !text.isEmpty {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = "P\(shared.selectionPage ?? 1) · \(String(trimmed.prefix(230)))"
                onAttachSelection(snippet)
            }
        } label: {
            HStack(spacing: 5) {
                Image.ic(Ic.messageCircle).font(.system(size: 12))
                Text("引用选中内容").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle((shared.selectionText ?? "").isEmpty ? palette.gray400 : palette.accent)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.gray0.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.gray300.opacity(0.72)))
        }
        .buttonStyle(.plain)
        .disabled((shared.selectionText ?? "").isEmpty)
        .help("把 PDF 中选中的文本加入论文对话")
    }
}

/// Selection + load state shared between the PDFKit coordinator and SwiftUI.
@MainActor
@Observable
final class SharedPdfState {
    var selectionText: String?
    var selectionPage: Int?
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
    private var shared: SharedPdfState?
    private var onPageChange: ((Int, Int) -> Void)?
    private var currentZoom: Double = 1
    private var lastAppliedZoom: Double = 0
    private var baseFitFactor: CGFloat = 0
    private var lastFocusToken = 0

    func attach(_ view: PDFView, shared: SharedPdfState, onPageChange: @escaping (Int, Int) -> Void) {
        self.pdfView = view
        self.shared = shared
        self.onPageChange = onPageChange

        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self] _ in self?.reportPage() })
        observers.append(NotificationCenter.default.addObserver(
            forName: .PDFViewDidChangeSelection, object: view, queue: .main
        ) { [weak self] _ in self?.reportSelection() })
    }

    func loadPaperIfNeeded(paperId: String) {
        guard loadedPaperId != paperId else { return }
        loadedPaperId = paperId
        let url = ApiClient().papersPdfURL(id: paperId)
        Task { @MainActor in
            let document = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url)
            }.value
            guard let pdfView = pdfView, loadedPaperId == paperId else { return }
            if let document {
                pdfView.document = document
                shared?.loaded = true
                shared?.failed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.baseFitFactor = pdfView.scaleFactorForSizeToFit
                    self?.applyZoom()
                    self?.restoreProgress()
                    self?.processPendingFocus()
                }
            } else {
                shared?.loaded = false
                shared?.failed = true
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
        lastAppliedZoom = currentZoom
        let fit = baseFitFactor > 0 ? baseFitFactor : pdfView.scaleFactorForSizeToFit
        guard fit > 0 else { return }
        pdfView.minScaleFactor = fit * 0.6
        pdfView.maxScaleFactor = fit * 2.4
        pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, fit * CGFloat(currentZoom)))
    }

    private func restoreProgress() {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0 else { return }
        let stored = LocalPrefs.pdfProgress(paperId: loadedPaperId ?? "")
        guard stored > 1 else { return }
        let index = min(document.pageCount - 1, max(0, Int(stored / 100 * Double(document.pageCount))))
        if let page = document.page(at: index) {
            pdfView.go(to: page)
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
            x: bounds.width * bbox[0] / 1000,
            y: bounds.height * (1 - bbox[3] / 1000),
            width: bounds.width * (bbox[2] - bbox[0]) / 1000,
            height: bounds.height * (bbox[3] - bbox[1]) / 1000
        )
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.borderWidth = 0 // transparent border, accent fill at ~30%
        #if os(iOS)
        annotation.fillColor = (shared.focusColor ?? UIColor.systemBlue).withAlphaComponent(0.3)
        #else
        annotation.fillColor = (shared.focusColor ?? NSColor.controlAccentColor).withAlphaComponent(0.3)
        #endif
        page.addAnnotation(annotation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak page, weak annotation] in
            if let annotation { page?.removeAnnotation(annotation) }
        }
    }

    private func reportPage() {
        guard let pdfView, let document = pdfView.document, document.pageCount > 0,
              let current = pdfView.currentPage, let onPageChange else { return }
        onPageChange(document.index(for: current), document.pageCount)
    }

    private func reportSelection() {
        guard let pdfView else { return }
        let selection = pdfView.currentSelection
        let text = selection?.string
        shared?.selectionText = (text?.isEmpty == false) ? text : nil
        if let selection, let page = selection.pages.first, let document = pdfView.document {
            shared?.selectionPage = document.index(for: page) + 1
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
    let zoom: Double
    let shared: SharedPdfState
    let onPageChange: (Int, Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.pageShadowsEnabled = true
        view.backgroundColor = .systemBackground
        context.coordinator.attach(view, shared: shared, onPageChange: onPageChange)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.updateZoom(zoom)
        context.coordinator.loadPaperIfNeeded(paperId: paperId)
        context.coordinator.processPendingFocus()
    }

    func makeCoordinator() -> PdfCoordinatorBase { PdfCoordinatorBase() }
}
#else
struct PlatformPdfView: NSViewRepresentable {
    let paperId: String
    let zoom: Double
    let shared: SharedPdfState
    let onPageChange: (Int, Int) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.pageShadowsEnabled = true
        view.backgroundColor = .controlBackgroundColor
        context.coordinator.attach(view, shared: shared, onPageChange: onPageChange)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.updateZoom(zoom)
        context.coordinator.loadPaperIfNeeded(paperId: paperId)
        context.coordinator.processPendingFocus()
    }

    func makeCoordinator() -> PdfCoordinatorBase { PdfCoordinatorBase() }
}
#endif
