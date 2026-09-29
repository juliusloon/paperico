import { useEffect, useRef, useState } from 'react';
import { ChevronDown, FileText, Maximize2, MessageCircle } from 'lucide-react';
import MetaCard from './MetaCard';
import ChatPanel from '../chat/ChatPanel';

const CARD_HEADER = 48;
const SPLITTER_SIZE = 10;

export default function RightPanel() {
  const stackRef = useRef<HTMLDivElement>(null);
  const [stackHeight, setStackHeight] = useState(0);
  const [topHeight, setTopHeight] = useState<number | null>(null);

  useEffect(() => {
    const stack = stackRef.current;
    if (!stack) return;
    const updateSize = () => {
      const height = stack.clientHeight;
      setStackHeight(height);
      setTopHeight((current) => clamp(current ?? height * .4, CARD_HEADER, height - CARD_HEADER - SPLITTER_SIZE));
    };
    updateSize();
    const observer = new ResizeObserver(updateSize);
    observer.observe(stack);
    return () => observer.disconnect();
  }, []);

  const startResize = (event: React.PointerEvent) => {
    event.preventDefault();
    const stack = stackRef.current;
    if (!stack) return;
    const rect = stack.getBoundingClientRect();
    document.body.classList.add('is-resizing-y');
    const onMove = (moveEvent: PointerEvent) => {
      setTopHeight(clamp(moveEvent.clientY - rect.top, CARD_HEADER, rect.height - CARD_HEADER - SPLITTER_SIZE));
    };
    const onUp = () => {
      window.removeEventListener('pointermove', onMove);
      document.body.classList.remove('is-resizing-y');
    };
    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp, { once: true });
  };

  const resolvedTop = topHeight ?? Math.max(CARD_HEADER, stackHeight * .4);
  const bottomHeight = stackHeight - resolvedTop - SPLITTER_SIZE;
  const infoCollapsed = resolvedTop <= CARD_HEADER + 2;
  const chatCollapsed = bottomHeight <= CARD_HEADER + 2;

  return (
    <div
      ref={stackRef}
      className="right-stack"
      style={stackHeight ? { gridTemplateRows: `${resolvedTop}px ${SPLITTER_SIZE}px minmax(${CARD_HEADER}px, 1fr)` } : undefined}
    >
      <section className={`side-card info-card${infoCollapsed ? ' collapsed' : ''}`}>
        <CardTitle icon={FileText} title="论文信息" code="INFO" onMaximize={() => setTopHeight(stackHeight - CARD_HEADER - SPLITTER_SIZE)} />
        <div className="side-card-content"><MetaCard /></div>
      </section>

      <div className="side-stack-resizer" role="separator" aria-label="调整论文信息与论文对话高度" aria-orientation="horizontal" onPointerDown={startResize}><span /></div>

      <section className={`side-card chat-card${chatCollapsed ? ' collapsed' : ''}`}>
        <CardTitle icon={MessageCircle} title="论文对话" code="CHAT" onMaximize={() => setTopHeight(CARD_HEADER)} />
        <div className="side-card-content"><ChatPanel /></div>
      </section>
    </div>
  );
}

function CardTitle({ icon: Icon, title, code, onMaximize }: { icon: typeof FileText; title: string; code: string; onMaximize: () => void }) {
  return <header className="side-card-titlebar"><span><Icon size={16} /><strong>{title}</strong><small>{code}</small></span><button type="button" onClick={onMaximize} title={`${title}占据整列`}><Maximize2 size={14} /></button></header>;
}

/** Mobile "信息与对话" tab: collapsible meta card on top, chat filling the rest. */
export function MobileSidePanel() {
  return (
    <div className="mobile-side-panel">
      <details className="mobile-info-section">
        <summary>
          <FileText size={15} /><strong>论文信息</strong><small>INFO</small><ChevronDown size={15} className="mobile-info-caret" />
        </summary>
        <div className="mobile-info-body"><MetaCard /></div>
      </details>
      <section className="side-card mobile-chat-section">
        <header className="side-card-titlebar"><span><MessageCircle size={16} /><strong>论文对话</strong><small>CHAT</small></span></header>
        <div className="side-card-content"><ChatPanel /></div>
      </section>
    </div>
  );
}

function clamp(value: number, min: number, max: number) {
  return Math.min(Math.max(value, min), Math.max(min, max));
}
