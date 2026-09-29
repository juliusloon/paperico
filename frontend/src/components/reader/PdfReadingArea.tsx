import { useEffect, useRef, useState } from 'react';
import { AlertTriangle, Loader2 } from 'lucide-react';
import {
  GlobalWorkerOptions, TextLayer, getDocument,
  type PDFDocumentProxy, type PDFPageProxy, type RenderTask,
} from 'pdfjs-dist';
import pdfWorkerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';
import { useReaderStore } from '../../stores';
import type { Block } from '../../api/types';

GlobalWorkerOptions.workerSrc = pdfWorkerUrl;

/** bbox fractions of a block on its page (MinerU 0–1000 → 0–1, docs/bbox-coordinate-system.md). */
type FocusRect = { left: number; top: number; width: number; height: number };

type PdfReadingAreaProps = {
  paperId: string;
  zoom: number;
  initialProgress: number;
  active: boolean;
  onProgressChange: (progress: number) => void;
  onZoomChange: (zoom: number) => void;
  onTextSelect: (pageNumber: number) => void;
};

const FOCUS_FLASH_MS = 1800;

export default function PdfReadingArea({
  paperId, zoom, initialProgress, active, onProgressChange, onZoomChange, onTextSelect,
}: PdfReadingAreaProps) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const initialProgressRef = useRef(initialProgress);
  const restoredRef = useRef(false);
  const progressFrameRef = useRef<number | null>(null);
  const zoomRef = useRef(zoom);
  const zoomAnchorFrameRef = useRef<number | null>(null);
  const focusTimerRef = useRef<number | null>(null);
  const [document, setDocument] = useState<PDFDocumentProxy | null>(null);
  const [containerWidth, setContainerWidth] = useState(0);
  const [error, setError] = useState('');
  // T2.3: block → page jump + bbox flash highlight, driven by pendingPdfFocus.
  const pendingPdfFocus = useReaderStore((s) => s.pendingPdfFocus);
  const blocks = useReaderStore((s) => s.paper?.blocks);
  const [focus, setFocus] = useState<{ pageNumber: number; rect: FocusRect | null } | null>(null);

  useEffect(() => {
    if (!active || !pendingPdfFocus) return;
    const block: Block | undefined = blocks?.find((b) => b.id === pendingPdfFocus.blockId);
    // Consume the request either way so a later switch to the PDF tab does
    // not replay a stale focus.
    useReaderStore.setState({ pendingPdfFocus: null });
    if (!block || block.page_idx == null || !scrollRef.current) return;
    const pageNumber = block.page_idx + 1;
    scrollRef.current
      .querySelector<HTMLElement>(`[data-page-number="${pageNumber}"]`)
      ?.scrollIntoView({ behavior: 'smooth', block: 'start' });

    const bbox = block.bbox;
    const rect: FocusRect | null = bbox && bbox.length === 4 && bbox.every((v) => Number.isFinite(v) && v >= 0)
      ? { left: bbox[0] / 1000, top: bbox[1] / 1000, width: (bbox[2] - bbox[0]) / 1000, height: (bbox[3] - bbox[1]) / 1000 }
      : null; // legacy rows without a usable bbox: page jump only
    if (focusTimerRef.current != null) window.clearTimeout(focusTimerRef.current);
    setFocus({ pageNumber, rect });
    focusTimerRef.current = window.setTimeout(() => setFocus(null), FOCUS_FLASH_MS);
  }, [active, pendingPdfFocus, blocks]);

  useEffect(() => () => {
    if (focusTimerRef.current != null) window.clearTimeout(focusTimerRef.current);
  }, []);

  useEffect(() => {
    let disposed = false;
    const loadingTask = getDocument({ url: `/api/papers/${paperId}/pdf` });
    loadingTask.promise.then((nextDocument) => {
      if (!disposed) setDocument(nextDocument);
    }).catch((reason: unknown) => {
      if (!disposed) setError(reason instanceof Error ? reason.message : 'PDF 加载失败');
    });
    return () => {
      disposed = true;
      void loadingTask.destroy();
    };
  }, [paperId]);

  useEffect(() => {
    const container = scrollRef.current;
    if (!container) return;
    const observer = new ResizeObserver(([entry]) => setContainerWidth(entry.contentRect.width));
    observer.observe(container);
    setContainerWidth(container.clientWidth);
    return () => observer.disconnect();
  }, []);

  useEffect(() => { zoomRef.current = zoom; }, [zoom]);

  useEffect(() => {
    const container = scrollRef.current;
    if (!container) return;
    const handleTrackpadZoom = (event: WheelEvent) => {
      if (!event.ctrlKey) return;
      event.preventDefault();
      const previousZoom = zoomRef.current;
      const nextZoom = Math.max(.6, Math.min(2.4, previousZoom * Math.exp(-event.deltaY * .0045)));
      if (Math.abs(nextZoom - previousZoom) < .002) return;

      const bounds = container.getBoundingClientRect();
      const pointerX = event.clientX - bounds.left;
      const pointerY = event.clientY - bounds.top;
      const contentX = container.scrollLeft + pointerX;
      const contentY = container.scrollTop + pointerY;
      const zoomRatio = nextZoom / previousZoom;

      zoomRef.current = nextZoom;
      onZoomChange(nextZoom);
      if (zoomAnchorFrameRef.current != null) cancelAnimationFrame(zoomAnchorFrameRef.current);
      zoomAnchorFrameRef.current = requestAnimationFrame(() => {
        zoomAnchorFrameRef.current = requestAnimationFrame(() => {
          zoomAnchorFrameRef.current = null;
          container.scrollLeft = Math.max(0, contentX * zoomRatio - pointerX);
          container.scrollTop = Math.max(0, contentY * zoomRatio - pointerY);
        });
      });
    };
    container.addEventListener('wheel', handleTrackpadZoom, { passive: false });
    return () => {
      container.removeEventListener('wheel', handleTrackpadZoom);
      if (zoomAnchorFrameRef.current != null) cancelAnimationFrame(zoomAnchorFrameRef.current);
    };
  }, [onZoomChange]);

  useEffect(() => {
    if (!document || !active || restoredRef.current) return;
    let firstFrame = 0;
    let secondFrame = 0;
    firstFrame = requestAnimationFrame(() => {
      secondFrame = requestAnimationFrame(() => {
        const container = scrollRef.current;
        if (!container) return;
        const maxScroll = Math.max(0, container.scrollHeight - container.clientHeight);
        container.scrollTop = maxScroll * initialProgressRef.current / 100;
        restoredRef.current = true;
      });
    });
    return () => {
      cancelAnimationFrame(firstFrame);
      cancelAnimationFrame(secondFrame);
    };
  }, [document, active]);

  const handleScroll = () => {
    if (progressFrameRef.current != null) return;
    progressFrameRef.current = requestAnimationFrame(() => {
      progressFrameRef.current = null;
      const container = scrollRef.current;
      if (!container) return;
      onProgressChange(calculateScrollProgress(container));
    });
  };

  useEffect(() => () => {
    if (progressFrameRef.current != null) cancelAnimationFrame(progressFrameRef.current);
  }, []);

  const availableWidth = Math.max(280, containerWidth - 64);

  return (
    <div
      ref={scrollRef}
      className={`pdf-reading-scroll reader-mode-panel${active ? '' : ' is-hidden'}`}
      onScroll={handleScroll}
      aria-label="原始 PDF 阅读器"
    >
      {!document && !error && <div className="pdf-reader-state"><Loader2 className="animate-spin" size={22} /><span>正在载入原始 PDF…</span></div>}
      {error && <div className="pdf-reader-state pdf-reader-error"><AlertTriangle size={22} /><strong>无法打开原始 PDF</strong><span>{error}</span></div>}
      {document && (
        <div className="pdf-page-stack">
          {Array.from({ length: document.numPages }, (_, index) => (
            <PdfPage
              key={index + 1}
              document={document}
              pageNumber={index + 1}
              availableWidth={availableWidth}
              zoom={zoom}
              scrollRoot={scrollRef}
              onTextSelect={onTextSelect}
              highlight={focus?.pageNumber === index + 1 ? focus.rect ?? undefined : undefined}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function PdfPage({
  document, pageNumber, availableWidth, zoom, scrollRoot, onTextSelect, highlight,
}: {
  document: PDFDocumentProxy;
  pageNumber: number;
  availableWidth: number;
  zoom: number;
  scrollRoot: React.RefObject<HTMLDivElement | null>;
  onTextSelect: (pageNumber: number) => void;
  highlight?: FocusRect;
}) {
  const shellRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const textLayerRef = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(() => !('IntersectionObserver' in window));
  const [ratio, setRatio] = useState(11 / 8.5);
  const [page, setPage] = useState<PDFPageProxy | null>(null);

  useEffect(() => {
    const shell = shellRef.current;
    if (!shell) return;
    if (!('IntersectionObserver' in window)) return;
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) {
        setVisible(true);
        observer.disconnect();
      }
    }, { root: scrollRoot.current, rootMargin: '900px 0px' });
    observer.observe(shell);
    return () => observer.disconnect();
  }, [scrollRoot]);

  useEffect(() => {
    if (!visible) return;
    let disposed = false;
    document.getPage(pageNumber).then((nextPage) => {
      if (disposed) return;
      const viewport = nextPage.getViewport({ scale: 1 });
      setRatio(viewport.height / viewport.width);
      setPage(nextPage);
    });
    return () => { disposed = true; };
  }, [document, pageNumber, visible]);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!page || !canvas || availableWidth <= 0) return;
    const baseViewport = page.getViewport({ scale: 1 });
    const scale = Math.max(.2, availableWidth / baseViewport.width * zoom);
    const viewport = page.getViewport({ scale });
    shellRef.current?.style.setProperty('--total-scale-factor', String(scale));
    const outputScale = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.floor(viewport.width * outputScale);
    canvas.height = Math.floor(viewport.height * outputScale);
    canvas.style.width = `${viewport.width}px`;
    canvas.style.height = `${viewport.height}px`;
    const renderTask: RenderTask = page.render({
      canvas,
      viewport,
      transform: outputScale === 1 ? undefined : [outputScale, 0, 0, outputScale, 0, 0],
    });
    renderTask.promise.catch((reason: unknown) => {
      if (!(reason instanceof Error && reason.name === 'RenderingCancelledException')) console.error(reason);
    });
    return () => renderTask.cancel();
  }, [page, availableWidth, zoom]);

  useEffect(() => {
    const container = textLayerRef.current;
    if (!page || !container || availableWidth <= 0) return;
    const baseViewport = page.getViewport({ scale: 1 });
    const scale = Math.max(.2, availableWidth / baseViewport.width * zoom);
    const viewport = page.getViewport({ scale });
    let disposed = false;
    let textLayer: TextLayer | null = null;
    container.replaceChildren();
    page.getTextContent().then((textContent) => {
      if (disposed) return;
      textLayer = new TextLayer({ textContentSource: textContent, container, viewport });
      return textLayer.render();
    }).catch((reason: unknown) => {
      if (!(reason instanceof Error && reason.name === 'AbortException')) console.error(reason);
    });
    return () => {
      disposed = true;
      textLayer?.cancel();
      container.replaceChildren();
    };
  }, [page, availableWidth, zoom]);

  const pageWidth = Math.max(240, availableWidth * zoom);
  return (
    <div
      ref={shellRef}
      className="pdf-page-shell"
      style={{ width: `${pageWidth}px`, aspectRatio: `1 / ${ratio}` }}
      aria-label={`PDF 第 ${pageNumber} 页`}
      data-page-number={pageNumber}
      onMouseUp={() => onTextSelect(pageNumber)}
    >
      {visible && <canvas ref={canvasRef} />}
      {visible && <div ref={textLayerRef} className="textLayer pdf-text-layer" />}
      {highlight && (
        <div
          className="pdf-focus-highlight"
          style={{
            left: `${highlight.left * 100}%`,
            top: `${highlight.top * 100}%`,
            width: `${highlight.width * 100}%`,
            height: `${highlight.height * 100}%`,
          }}
        />
      )}
    </div>
  );
}

function calculateScrollProgress(container: HTMLElement) {
  const maxScroll = Math.max(0, container.scrollHeight - container.clientHeight);
  if (maxScroll === 0 || container.scrollTop <= 1) return 0;
  const endThreshold = Math.max(2, Math.min(32, container.clientHeight * .04));
  if (maxScroll - container.scrollTop <= endThreshold) return 100;
  return Math.max(0, Math.min(100, container.scrollTop / maxScroll * 100));
}
