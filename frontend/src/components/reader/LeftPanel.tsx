import { useEffect, useMemo, useRef } from 'react';
import { AlignLeft, ChevronRight, Grid2x2, List, PanelLeftClose } from 'lucide-react';
import { useReaderStore } from '../../stores';

export default function LeftPanel() {
  const {
    paper, activeBlockId, setActiveBlock, leftPanelDensity, setLeftPanelDensity,
    toggleLeftPanel, highlightedEntities, addAttachedContext,
  } = useReaderStore();
  const listRef = useRef<HTMLDivElement>(null);
  const blocks = paper?.blocks || [];
  const entities = paper?.entities || [];

  const entityMap = useMemo(() => new Map(entities.map((entity) => [entity.id, entity])), [entities]);
  const visibleBlocks = useMemo(
    () => blocks.filter((block) => block.kind === 'section_heading' || block.one_liner || block.role_in_narrative),
    [blocks],
  );

  useEffect(() => {
    if (!activeBlockId || !listRef.current) return;
    const active = listRef.current.querySelector<HTMLElement>(`[data-nav-block="${CSS.escape(activeBlockId)}"]`);
    active?.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }, [activeBlockId]);

  const scrollToBlock = (blockId: string) => {
    setActiveBlock(blockId);
    const element = document.getElementById(`block-${blockId}`);
    if (element) {
      element.scrollIntoView({ behavior: 'smooth', block: 'center' });
      element.classList.add('block-highlighted');
      window.setTimeout(() => element.classList.remove('block-highlighted'), 1800);
    }
  };

  return (
    <div className="logic-panel">
      <header className="logic-header">
        <div><span>LOGIC MAP</span><strong>论文逻辑链</strong></div>
        <div className="logic-actions">
          <button onClick={() => setLeftPanelDensity(leftPanelDensity === 'compact' ? 'detailed' : 'compact')} title={leftPanelDensity === 'compact' ? '显示方法标签' : '隐藏方法标签'}>
            {leftPanelDensity === 'compact' ? <Grid2x2 size={13} /> : <List size={13} />}
          </button>
          <button onClick={toggleLeftPanel} title="收起逻辑链"><PanelLeftClose size={13} /></button>
        </div>
      </header>

      <div ref={listRef} className="logic-list">
        {visibleBlocks.map((block, index) => {
          const isActive = activeBlockId === block.id;
          const isHeading = block.kind === 'section_heading';
          const isHighlighted = highlightedEntities.length > 0 && block.entity_refs.some((id) => highlightedEntities.includes(id));
          const page = block.page_idx == null ? null : block.page_idx + 1;
          return (
            <button
              key={block.id}
              data-nav-block={block.id}
              className={`logic-node${isActive ? ' active' : ''}${isHeading ? ' heading' : ''}${isHighlighted ? ' entity-active' : ''}`}
              onClick={() => scrollToBlock(block.id)}
            >
              <span className="logic-track" aria-hidden="true"><i />{index < visibleBlocks.length - 1 && <b />}</span>
              <span className="logic-copy">
                <small>{isHeading ? 'SECTION' : block.role_in_narrative || `NODE ${String(index + 1).padStart(2, '0')}`}{page ? ` · P${page}` : ''}</small>
                <strong>{isHeading ? block.text_original || block.section_title : block.one_liner || block.text_original.slice(0, 48)}</strong>
                {leftPanelDensity === 'detailed' && block.entity_refs.length > 0 && (
                  <span className="entity-chips">
                    {block.entity_refs.map((id) => entityMap.get(id)).filter(Boolean).map((entity) => (
                      <em
                        key={entity!.id}
                        role="button"
                        tabIndex={0}
                        title={`将 ${entity!.name} 加入论文对话`}
                        onClick={(event) => {
                          event.stopPropagation();
                          addAttachedContext({ type: 'method_card', ref_entity_id: entity!.id, ref_block_id: block.id, snippet: entity!.name });
                        }}
                        onKeyDown={(event) => {
                          event.stopPropagation();
                          if (event.key === 'Enter' || event.key === ' ') {
                            event.preventDefault();
                            addAttachedContext({ type: 'method_card', ref_entity_id: entity!.id, ref_block_id: block.id, snippet: entity!.name });
                          }
                        }}
                      >
                        {entity!.name}
                      </em>
                    ))}
                  </span>
                )}
              </span>
              <ChevronRight className="logic-chevron" size={12} />
            </button>
          );
        })}
        {visibleBlocks.length === 0 && <div className="logic-empty"><AlignLeft size={22} /><span>解析完成后，逻辑节点会出现在这里。</span></div>}
      </div>

      <footer className="logic-footer"><span className="mini-brand">P</span><span><strong>Paperico</strong><small>结构跟随阅读位置同步</small></span></footer>
    </div>
  );
}
