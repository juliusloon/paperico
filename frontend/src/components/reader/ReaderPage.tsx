import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { AlertCircle, BookOpenText, ListTree, Loader2, MessagesSquare } from 'lucide-react';
import { useReaderStore, useChatStore } from '../../stores';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import type { MethodEntity } from '../../api/types';
import ReadingArea from './ReadingArea';
import RightPanel, { MobileSidePanel } from './RightPanel';
import MobileOutline from './MobileOutline';
import WorkspaceNav from '../layout/WorkspaceNav';

type ResizeSide = 'left' | 'right';
type MobileTab = 'outline' | 'reading' | 'chat';

const MOBILE_READER_QUERY = '(max-width: 900px)';

export default function ReaderPage() {
  const { paperId } = useParams<{ paperId: string }>();
  const [searchParams] = useSearchParams();
  const requestedView = searchParams.get('view');
  const initialView = requestedView === 'pdf' || requestedView === 'text' ? requestedView : undefined;
  const { paper, loading, error, fetchPaper, refreshPaper, leftPanelCollapsed, setActiveBlock, addAttachedContext, attachedContext } = useReaderStore();
  const { fetchSessions } = useChatStore();
  const shellRef = useRef<HTMLDivElement>(null);
  const [leftWidth, setLeftWidth] = useState(() => Number(localStorage.getItem('paperico:left-width')) || 250);
  const [rightWidth, setRightWidth] = useState(() => Number(localStorage.getItem('paperico:right-width')) || 370);
  const isMobile = useMediaQuery(MOBILE_READER_QUERY);
  const [mobileTab, setMobileTab] = useState<MobileTab>('reading');
  const [visitedTabs, setVisitedTabs] = useState<ReadonlySet<MobileTab>>(() => new Set<MobileTab>(['reading']));
  const paperStatus = paper?.paper.status;

  useEffect(() => {
    if (paperId) {
      localStorage.setItem('paperico:last-paper', paperId);
      fetchPaper(paperId);
      fetchSessions(paperId);
    }
  }, [paperId, fetchPaper, fetchSessions]);

  useEffect(() => {
    if (!paperId || !paperStatus || ['ready', 'error'].includes(paperStatus)) return;
    const timer = window.setInterval(() => refreshPaper(paperId).catch(() => {}), 3500);
    return () => window.clearInterval(timer);
  }, [paperId, paperStatus, refreshPaper]);

  const startResize = useCallback((side: ResizeSide, event: React.PointerEvent) => {
    event.preventDefault();
    const startX = event.clientX;
    const startLeft = leftWidth;
    const startRight = rightWidth;
    const shellWidth = shellRef.current?.clientWidth || window.innerWidth;
    document.body.classList.add('is-resizing');

    const onMove = (moveEvent: PointerEvent) => {
      const delta = moveEvent.clientX - startX;
      if (side === 'left') {
        const next = Math.max(190, Math.min(390, startLeft + delta));
        setLeftWidth(Math.max(190, Math.min(next, shellWidth - rightWidth - 520)));
      } else {
        const next = Math.max(310, Math.min(520, startRight - delta));
        setRightWidth(Math.max(310, Math.min(next, shellWidth - (leftPanelCollapsed ? 0 : leftWidth) - 520)));
      }
    };
    const onUp = () => {
      window.removeEventListener('pointermove', onMove);
      document.body.classList.remove('is-resizing');
    };
    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp, { once: true });
  }, [leftWidth, rightWidth, leftPanelCollapsed]);

  useEffect(() => { localStorage.setItem('paperico:left-width', String(leftWidth)); }, [leftWidth]);
  useEffect(() => { localStorage.setItem('paperico:right-width', String(rightWidth)); }, [rightWidth]);

  const switchTab = useCallback((tab: MobileTab) => {
    setMobileTab(tab);
    setVisitedTabs((current) => current.has(tab) ? current : new Set(current).add(tab));
  }, []);

  const handleOutlineNavigate = useCallback((blockId: string) => {
    setActiveBlock(blockId);
    switchTab('reading');
    if (useReaderStore.getState().viewMode === 'pdf') {
      useReaderStore.getState().requestPdfFocus(blockId);
      return;
    }
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        document.getElementById(`block-${blockId}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
      });
    });
  }, [setActiveBlock, switchTab]);

  const handleEntityChat = useCallback((entity: MethodEntity, blockId: string) => {
    addAttachedContext({
      type: 'method_card',
      ref_entity_id: entity.id,
      ref_block_id: blockId,
      snippet: entity.name,
    });
    if (useReaderStore.getState().viewMode === 'pdf') {
      const target = entity.block_refs.find((id) => id !== blockId) || blockId;
      useReaderStore.getState().requestPdfFocus(target);
    }
    switchTab('chat');
  }, [addAttachedContext, switchTab]);

  if (loading) {
    return <div className="reader-state"><Loader2 size={28} className="animate-spin" /><span>正在打开论文工作台…</span></div>;
  }

  if (!paper) {
    return <div className="reader-state" role="alert"><AlertCircle size={28} /><span>{error || '没有找到这篇论文'}</span><div className="pdf-error-actions"><button className="primary-action" onClick={() => paperId && fetchPaper(paperId)}>重新载入</button><Link className="secondary-action" to="/library">返回论文库</Link></div></div>;
  }

  if (isMobile) {
    const tabs: Array<{ key: MobileTab; label: string; icon: typeof ListTree; badge?: number }> = [
      { key: 'outline', label: '逻辑链', icon: ListTree },
      { key: 'reading', label: '正文', icon: BookOpenText },
      { key: 'chat', label: '对话', icon: MessagesSquare, badge: attachedContext.length },
    ];
    return (
      <div className="reader-shell is-mobile">
        <header className="mobile-reader-topbar">
          <WorkspaceNav collapsed currentPaperId={paper.paper.id} />
          <nav className="mobile-reader-tabs" role="tablist" aria-label="阅读器视图切换">
            {tabs.map(({ key, label, icon: Icon, badge }) => (
              <button
                key={key}
                role="tab"
                aria-selected={mobileTab === key}
                className={mobileTab === key ? 'active' : ''}
                onClick={() => switchTab(key)}
              >
                <Icon size={15} /><span>{label}</span>
                {badge ? <i className="mobile-tab-badge">{badge}</i> : null}
              </button>
            ))}
          </nav>
        </header>
        <div className="mobile-reader-body">
          <div className={`mobile-reader-pane${mobileTab === 'reading' ? '' : ' is-hidden'}`}>
            <ReadingArea key={`${paperId}:${initialView || ''}`} initialView={initialView} mobile onOutlineResize={() => {}} />
          </div>
          {visitedTabs.has('outline') && (
            <div className={`mobile-reader-pane${mobileTab === 'outline' ? '' : ' is-hidden'}`}>
              <MobileOutline onNavigate={handleOutlineNavigate} onEntityChat={handleEntityChat} />
            </div>
          )}
          {visitedTabs.has('chat') && (
            <div className={`mobile-reader-pane${mobileTab === 'chat' ? '' : ' is-hidden'}`}>
              <MobileSidePanel />
            </div>
          )}
        </div>
      </div>
    );
  }

  return (
    <div
      ref={shellRef}
      className="reader-shell"
      style={{
        gridTemplateColumns: `minmax(500px, 1fr) 8px ${rightWidth}px`,
      }}
    >
      <main className="reader-center" style={{ '--outline-width': `${leftPanelCollapsed ? 0 : leftWidth}px` } as React.CSSProperties}>
        <ReadingArea key={`${paperId}:${initialView || ''}`} initialView={initialView} onOutlineResize={(event) => startResize('left', event)} />
      </main>
      <ResizeHandle label="调整右侧卡片宽度" onPointerDown={(e) => startResize('right', e)} />
      <aside className="reader-right"><RightPanel /></aside>
    </div>
  );
}

function ResizeHandle({ label, onPointerDown }: { label: string; onPointerDown: (e: React.PointerEvent) => void }) {
  return <div className="resize-handle" role="separator" aria-label={label} aria-orientation="vertical" onPointerDown={onPointerDown}><span /></div>;
}
