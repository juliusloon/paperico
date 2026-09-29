import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle, CircleGauge, FileText, FileType2, Languages, Loader2, Pilcrow, RotateCcw,
  RefreshCw, ZoomIn, ZoomOut,
} from 'lucide-react';
import ReactMarkdown from 'react-markdown';
import remarkMath from 'remark-math';
import rehypeKatex from 'rehype-katex';
import { api } from '../../api/client';
import { useReaderStore } from '../../stores';
import type { Block, MethodEntity } from '../../api/types';
import OutlineNode from './OutlineNode';
import WorkspaceNav from '../layout/WorkspaceNav';

const PdfReadingArea = lazy(() => import('./PdfReadingArea'));

const STATUS_COPY: Record<string, string> = {
  uploaded: '等待开始', parsing: 'MinerU 正在恢复版面结构', parsed: '结构解析完成',
  normalizing: '正在整理文本块', analyzing: '正在翻译并提炼段落', reducing: '正在重建全文逻辑',
};

type ReadingAreaProps = {
  onOutlineResize: (event: React.PointerEvent) => void;
  mobile?: boolean;
  initialView?: ReaderViewMode;
};

type ReaderViewMode = 'text' | 'pdf';

export default function ReadingArea({ onOutlineResize, mobile = false, initialView }: ReadingAreaProps) {
  const {
    paper, bilingualMode, setBilingualMode, fontSize, setFontSize, leftPanelCollapsed,
    toggleLeftPanel, activeBlockId, setActiveBlock, addAttachedContext, refreshPaper,
  } = useReaderStore();
  const containerRef = useRef<HTMLDivElement>(null);
  const textProgressRestoredRef = useRef('');
  const blocks = paper?.blocks || [];
  const paperMeta = paper?.paper;
  const paperId = paperMeta?.id || '';
  const [viewMode, setViewMode] = useState<ReaderViewMode>(() => initialView || readStoredMode(paperId));
  // ChatPanel / MobileOutline live outside this component and need the mode
  // to decide between text scroll and PDF focus (T2.3).
  useEffect(() => { useReaderStore.setState({ viewMode }); }, [viewMode]);
  const [pdfVisited, setPdfVisited] = useState(() => (initialView || readStoredMode(paperId)) === 'pdf');
  const [textProgress, setTextProgress] = useState(() => readStoredNumber(`paperico:text-progress:${paperId}`, 0));
  const [pdfProgress, setPdfProgress] = useState(() => readStoredNumber(`paperico:pdf-progress:${paperId}`, 0));
  const [pdfZoom, setPdfZoom] = useState(() => readStoredNumber(`paperico:pdf-zoom:${paperId}`, 1));
  const [retranslateBusy, setRetranslateBusy] = useState(false);
  const [retranslateRequestedFor, setRetranslateRequestedFor] = useState('');
  const [retranslateError, setRetranslateError] = useState('');
  const entityMap = useMemo(() => new Map((paper?.entities || []).map((entity) => [entity.id, entity])), [paper?.entities]);
  const paperProcessing = Boolean(paperMeta && !['ready', 'error'].includes(paperMeta.status));
  const retranslateRequested = Boolean(paperMeta?.id && retranslateRequestedFor === paperMeta.id);
  const retranslateActive = retranslateBusy || (retranslateRequested && paperProcessing);
  const backgroundRetranslateError = retranslateRequested && paperMeta?.status === 'error' && paperMeta.error_message
    ? `重新翻译失败：${paperMeta.error_message}`
    : '';
  const visibleRetranslateError = retranslateError || backgroundRetranslateError;

  const handleScroll = useCallback(() => {
    const container = containerRef.current;
    if (!container) return;
    const scrollProgress = calculateScrollProgress(container);
    setTextProgress((current) => Math.abs(current - scrollProgress) < .01 ? current : scrollProgress);
    if (paperId && textProgressRestoredRef.current === paperId) {
      localStorage.setItem(`paperico:text-progress:${paperId}`, String(scrollProgress));
    }
    const targetY = container.getBoundingClientRect().top + Math.min(180, container.clientHeight * .25);
    let closestId = '';
    let closestDistance = Number.POSITIVE_INFINITY;
    container.querySelectorAll<HTMLElement>('[data-block-id]').forEach((element) => {
      const distance = Math.abs(element.getBoundingClientRect().top - targetY);
      if (distance < closestDistance) {
        closestDistance = distance;
        closestId = element.dataset.blockId || '';
      }
    });
    if (closestId && closestId !== useReaderStore.getState().activeBlockId) setActiveBlock(closestId);
  }, [paperId, setActiveBlock]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container || !paperId || !blocks.length || textProgressRestoredRef.current === paperId) return;
    const savedProgress = readStoredNumber(`paperico:text-progress:${paperId}`, 0);
    let firstFrame = 0;
    let secondFrame = 0;
    firstFrame = requestAnimationFrame(() => {
      secondFrame = requestAnimationFrame(() => {
        const maxScroll = Math.max(0, container.scrollHeight - container.clientHeight);
        textProgressRestoredRef.current = paperId;
        container.scrollTop = maxScroll * savedProgress / 100;
        handleScroll();
      });
    });
    return () => {
      cancelAnimationFrame(firstFrame);
      cancelAnimationFrame(secondFrame);
    };
  }, [paperId, blocks.length, handleScroll]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    container.addEventListener('scroll', handleScroll, { passive: true });
    handleScroll();
    return () => container.removeEventListener('scroll', handleScroll);
  }, [handleScroll, blocks.length]);

  useEffect(() => {
    const removeSelectionAction = () => document.getElementById('text-select-btn')?.remove();
    const handleSelectionChange = () => {
      const selection = window.getSelection();
      if (!selection || selection.isCollapsed || !selection.toString().trim()) removeSelectionAction();
    };
    const handlePointerDown = (event: PointerEvent) => {
      const action = document.getElementById('text-select-btn');
      if (action && event.target instanceof Node && !action.contains(event.target)) action.remove();
    };
    document.addEventListener('selectionchange', handleSelectionChange);
    document.addEventListener('pointerdown', handlePointerDown, true);
    return () => {
      document.removeEventListener('selectionchange', handleSelectionChange);
      document.removeEventListener('pointerdown', handlePointerDown, true);
      removeSelectionAction();
    };
  }, []);

  const scrollToBlock = (blockId: string) => {
    setActiveBlock(blockId);
    if (viewMode === 'pdf') {
      useReaderStore.getState().requestPdfFocus(blockId);
      return;
    }
    document.getElementById(`block-${blockId}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };

  const showSelectionAction = useCallback((refBlockId?: string, pdfPage?: number) => {
    const selection = window.getSelection();
    const text = selection?.toString().trim() || '';
    const existingAction = document.getElementById('text-select-btn');
    if (!selection || text.length < 3 || selection.rangeCount === 0) {
      existingAction?.remove();
      return;
    }
    const rect = selection.getRangeAt(0).getBoundingClientRect();
    existingAction?.remove();
    const button = document.createElement('button');
    button.id = 'text-select-btn';
    button.className = 'selection-action';
    button.style.top = `${Math.max(62, rect.top - 38)}px`;
    button.style.left = `${Math.min(window.innerWidth - 130, rect.left)}px`;
    button.textContent = '加入论文对话';
    button.onpointerdown = (event) => event.preventDefault();
    button.onclick = () => {
      addAttachedContext({
        type: 'text_selection',
        ref_block_id: refBlockId,
        snippet: pdfPage ? `P${pdfPage} · ${text.slice(0, 230)}` : text.slice(0, 240),
      });
      button.remove();
      selection.removeAllRanges();
    };
    document.body.appendChild(button);
    window.setTimeout(() => button.remove(), 4200);
  }, [addAttachedContext]);

  const handleTextSelect = useCallback((blockId: string) => {
    showSelectionAction(blockId);
  }, [showSelectionAction]);

  const handlePdfTextSelect = useCallback((pageNumber: number) => {
    showSelectionAction(undefined, pageNumber);
  }, [showSelectionAction]);

  const handleReparse = async () => {
    if (!paperMeta) return;
    await api.papers.reparse(paperMeta.id);
    await refreshPaper(paperMeta.id);
  };

  const handleRetranslate = async () => {
    if (!paperMeta || !blocks.length || retranslateBusy || paperProcessing) return;
    setRetranslateBusy(true);
    setRetranslateError('');
    try {
      await api.papers.retranslate(paperMeta.id);
      await refreshPaper(paperMeta.id);
      setRetranslateRequestedFor(paperMeta.id);
    } catch (error) {
      setRetranslateRequestedFor('');
      setRetranslateError(`重新翻译未启动：${error instanceof Error ? error.message : '未知错误'}`);
    } finally {
      setRetranslateBusy(false);
    }
  };

  const toggleLanguage = () => setBilingualMode(bilingualMode === 'original' ? 'bilingual' : 'original');
  const activeProgress = viewMode === 'pdf' ? pdfProgress : textProgress;

  const toggleViewMode = () => {
    const nextMode: ReaderViewMode = viewMode === 'text' ? 'pdf' : 'text';
    document.getElementById('text-select-btn')?.remove();
    window.getSelection()?.removeAllRanges();
    if (nextMode === 'pdf') setPdfVisited(true);
    setViewMode(nextMode);
    if (paperId) localStorage.setItem(`paperico:reader-mode:${paperId}`, nextMode);
  };

  const changeReadingScale = (direction: -1 | 1) => {
    if (viewMode === 'pdf') {
      handlePdfZoomChange(pdfZoom + direction * .1);
      return;
    }
    setFontSize(Math.max(13, Math.min(23, fontSize + direction)));
  };

  const handlePdfZoomChange = useCallback((nextZoom: number) => {
    const normalizedZoom = Math.max(.6, Math.min(2.4, Math.round(nextZoom * 100) / 100));
    setPdfZoom(normalizedZoom);
    if (paperId) localStorage.setItem(`paperico:pdf-zoom:${paperId}`, String(normalizedZoom));
  }, [paperId]);

  const handlePdfProgress = useCallback((nextProgress: number) => {
    setPdfProgress(nextProgress);
    if (paperId) localStorage.setItem(`paperico:pdf-progress:${paperId}`, String(nextProgress));
  }, [paperId]);

  return (
    <div className="reading-workspace">
      {!mobile && <WorkspaceNav collapsed={leftPanelCollapsed} onToggleOutline={toggleLeftPanel} currentPaperId={paperMeta?.id} />}

      {(mobile || !leftPanelCollapsed) && (
      <div className="reader-floating-tools" aria-label="阅读显示控制">
        <button className="floating-tool view-mode-tool" onClick={toggleViewMode} aria-label={viewMode === 'text' ? '切换到原始 PDF' : '切换到文本精读'} aria-pressed={viewMode === 'pdf'} title={viewMode === 'text' ? '文本精读，点击查看原始 PDF' : '原始 PDF，点击返回文本精读'}>
          {viewMode === 'text' ? <FileText size={17} /> : <FileType2 size={17} />}
        </button>
        <button className="floating-tool language-tool" onClick={toggleLanguage} disabled={viewMode === 'pdf'} aria-label={bilingualMode === 'original' ? '切换双语模式' : '切换原文模式'} aria-pressed={bilingualMode !== 'original'} title={viewMode === 'pdf' ? 'PDF 模式不提供译文切换' : bilingualMode === 'original' ? '原文模式，点击切换双语' : '双语模式，点击切换原文'}>
          {bilingualMode === 'original' ? <Pilcrow size={17} /> : <Languages size={17} />}
        </button>
        <button
          className={`floating-tool retranslate-tool${retranslateActive ? ' is-active' : ''}`}
          onClick={handleRetranslate}
          disabled={!paperMeta || !blocks.length || paperProcessing || retranslateBusy}
          aria-label="重新翻译本文献并重建逻辑链"
          aria-busy={retranslateActive}
          title={retranslateActive ? '正在重新翻译并重建逻辑链…' : '重新翻译本文献（补齐缺失译文与逻辑链）'}
        >
          {retranslateActive ? <Loader2 size={16} className="animate-spin" /> : <RefreshCw size={16} />}
          <span>{retranslateActive ? '重译中' : '重新翻译'}</span>
        </button>
        <span className="floating-tool progress-tool" title={`${viewMode === 'pdf' ? 'PDF' : '文本'}阅读进度 ${Math.round(activeProgress)}%`}><CircleGauge size={15} /><b>{Math.round(activeProgress)}%</b></span>
        <div className={`floating-tool floating-font-tools${viewMode === 'pdf' ? ' pdf-scale-tools' : ''}`}>
          <button onClick={() => changeReadingScale(-1)} aria-label={viewMode === 'pdf' ? '缩小 PDF 页面' : '缩小字号'}><ZoomOut size={15} /></button>
          <span>{viewMode === 'pdf' ? `${Math.round(pdfZoom * 100)}%` : fontSize}</span>
          <button onClick={() => changeReadingScale(1)} aria-label={viewMode === 'pdf' ? '放大 PDF 页面' : '放大字号'}><ZoomIn size={15} /></button>
        </div>
      </div>
      )}
      {retranslateActive && <div className="translation-retry-progress" role="status"><Loader2 size={14} className="animate-spin" /><span>正在重新翻译本文献并重建逻辑链…</span></div>}
      {visibleRetranslateError && <div className="translation-retry-notice" role="alert"><AlertTriangle size={14} /><span>{visibleRetranslateError}</span></div>}

      {viewMode === 'text' && !leftPanelCollapsed && !mobile && <div className="outline-resize-handle" role="separator" aria-label="调整结构目录宽度" onPointerDown={onOutlineResize} />}

      <div ref={containerRef} className={`reading-scroll reader-mode-panel${viewMode === 'text' ? '' : ' is-hidden'}`}>
        {paperMeta && blocks.length > 0 && (
          <article className={`paper-document${leftPanelCollapsed || mobile ? ' outline-collapsed' : ''}`} style={{ '--reading-size': `${fontSize}px` } as React.CSSProperties}>
            <div className="document-row document-header-row">
              <aside className="margin-document-title">
                <span>OUTLINE</span><strong>论文逻辑链</strong><small>{blocks.length} 个节点</small>
              </aside>
              <header className="paper-document-header document-content-cell">
                <span className="document-label">RESEARCH ARTICLE</span>
                <h1>{paperMeta.title || paperMeta.original_file_name || '未命名论文'}</h1>
                {paperMeta.title_zh && paperMeta.title_zh !== paperMeta.title && <p>{paperMeta.title_zh}</p>}
                <div>{paperMeta.authors?.slice(0, 6).join(' · ') || paperMeta.original_file_name}{paperMeta.year ? ` · ${paperMeta.year}` : ''}</div>
              </header>
            </div>

            {blocks.map((block, index) => (
              <div key={block.id} id={`block-${block.id}`} data-block-id={block.id} className={`document-row document-block-row block-kind-${block.kind}${activeBlockId === block.id ? ' active' : ''}`}>
                <OutlineNode
                  block={block}
                  entities={block.entity_refs.map((id) => entityMap.get(id)).filter((entity): entity is MethodEntity => Boolean(entity))}
                  index={index}
                  active={activeBlockId === block.id}
                  onClick={() => scrollToBlock(block.id)}
                  onEntityClick={(entity) => {
                    addAttachedContext({
                      type: 'method_card',
                      ref_entity_id: entity.id,
                      ref_block_id: block.id,
                      snippet: entity.name,
                    });
                    if (viewMode === 'pdf') {
                      const target = entity.block_refs.find((id) => id !== block.id) || block.id;
                      useReaderStore.getState().requestPdfFocus(target);
                    }
                  }}
                />
                <div className="document-content-cell"><BlockRenderer block={block} bilingualMode={bilingualMode} fontSize={fontSize} onSelect={handleTextSelect} /></div>
              </div>
            ))}
            <div className="document-row document-footer-row"><span /><footer className="document-end document-content-cell"><span>END OF PAPER</span></footer></div>
          </article>
        )}

        {paperMeta && blocks.length === 0 && paperMeta.status !== 'error' && (
          <div className="processing-stage">
            <span className="processing-glyph"><Loader2 size={23} className="animate-spin" /></span>
            <p className="section-kicker">PREPARING PAPER</p><h2>{STATUS_COPY[paperMeta.status] || '正在准备论文内容'}</h2>
            <p>可以留在此页，完成后正文和逻辑目录会自动出现。</p>
            <div className="stage-rail"><i className="done" /><i className={paperMeta.status !== 'uploaded' ? 'done' : ''} /><i /><i /></div>
          </div>
        )}

        {paperMeta?.status === 'error' && (
          <div className="processing-stage error-stage">
            <span className="processing-glyph"><AlertTriangle size={23} /></span><p className="section-kicker">PROCESSING STOPPED</p>
            <h2>论文处理没有完成</h2><p>{paperMeta.original_file_name}</p>
            {paperMeta.error_code && <code className="error-code-chip">{paperMeta.error_code}</code>}
            <code>{paperMeta.error_message || '请检查 API 配置后重新解析。'}</code>
            <button className="primary-action" onClick={handleReparse}><RotateCcw size={14} />重新解析</button>
          </div>
        )}
      </div>
      {pdfVisited && paperId && (
        <Suspense fallback={<div className={`pdf-reader-state reader-mode-panel${viewMode === 'pdf' ? '' : ' is-hidden'}`}><Loader2 className="animate-spin" size={22} /><span>正在准备 PDF 阅读器…</span></div>}>
          <PdfReadingArea
            key={paperId}
            paperId={paperId}
            zoom={pdfZoom}
            initialProgress={pdfProgress}
            active={viewMode === 'pdf'}
            onProgressChange={handlePdfProgress}
            onZoomChange={handlePdfZoomChange}
            onTextSelect={handlePdfTextSelect}
          />
        </Suspense>
      )}
      <span className="reading-progress" style={{ width: `${activeProgress}%` }} />
    </div>
  );
}

function readStoredMode(paperId: string): ReaderViewMode {
  if (!paperId) return 'text';
  return localStorage.getItem(`paperico:reader-mode:${paperId}`) === 'pdf' ? 'pdf' : 'text';
}

function readStoredNumber(key: string, fallback: number) {
  if (!key || key.endsWith(':')) return fallback;
  const stored = localStorage.getItem(key);
  if (stored == null) return fallback;
  const value = Number(stored);
  return Number.isFinite(value) ? value : fallback;
}

function calculateScrollProgress(container: HTMLElement) {
  const maxScroll = Math.max(0, container.scrollHeight - container.clientHeight);
  if (maxScroll === 0 || container.scrollTop <= 1) return 0;
  const endThreshold = Math.max(2, Math.min(32, container.clientHeight * .04));
  if (maxScroll - container.scrollTop <= endThreshold) return 100;
  return Math.max(0, Math.min(100, container.scrollTop / maxScroll * 100));
}

function BlockRenderer({ block, bilingualMode, fontSize, onSelect }: { block: Block; bilingualMode: string; fontSize: number; onSelect: (blockId: string) => void }) {
  const showOriginal = bilingualMode !== 'translation';
  const showTranslation = bilingualMode !== 'original';
  if (block.kind === 'section_heading') return <section className="paper-section-title"><span>§</span><div>{showOriginal && <h2>{block.text_original || block.section_title}</h2>}{showTranslation && block.text_zh && <p>{block.text_zh}</p>}</div></section>;
  if (block.kind === 'figure') {
    const translatedCaption = block.caption_zh || block.text_zh;
    return <figure className="paper-figure">{block.image_path && <img src={`/api/files/${block.image_path}`} alt={translatedCaption || block.caption_original || '论文图'} onClick={() => useReaderStore.getState().addAttachedContext({ type: 'figure', ref_block_id: block.id })} />}<figcaption>{showOriginal && block.caption_original && <RichText text={block.caption_original} />}{showTranslation && translatedCaption && <div className="translated-caption"><RichText text={translatedCaption} /></div>}</figcaption>{block.core_takeaways?.length > 0 && <aside><strong>图表要点</strong>{block.core_takeaways.map((item) => <p key={item}>{item}</p>)}</aside>}</figure>;
  }
  if (block.kind === 'table') {
    const translatedCaption = block.caption_zh || block.text_zh;
    return <figure className="paper-table">{block.table_html ? <div className="table-scroll" dangerouslySetInnerHTML={{ __html: block.table_html }} /> : block.image_path ? <img src={`/api/files/${block.image_path}`} alt={translatedCaption || '论文表格'} /> : null}<figcaption>{showOriginal && block.caption_original && <RichText text={block.caption_original} />}{showTranslation && translatedCaption && <div className="translated-caption"><RichText text={translatedCaption} /></div>}</figcaption></figure>;
  }
  if (block.kind === 'equation') return <div className="paper-equation"><ReactMarkdown remarkPlugins={[remarkMath]} rehypePlugins={[rehypeKatex]}>{`$$${block.latex}$$`}</ReactMarkdown>{block.plain_explanation && <small>{block.plain_explanation}</small>}</div>;
  return <div className="paper-paragraph" onMouseUp={() => onSelect(block.id)}>{showOriginal && block.text_original && <RichText text={block.text_original} />}{showTranslation && block.text_zh && <div className="translation" style={{ fontSize: `${fontSize - 1}px` }}><RichText text={block.text_zh} /></div>}</div>;
}

function RichText({ text }: { text: string }) {
  return <div className="paper-rich-text"><ReactMarkdown remarkPlugins={[remarkMath]} rehypePlugins={[rehypeKatex]}>{text}</ReactMarkdown></div>;
}
