import type { Block, MethodEntity } from '../../api/types';

export function getOutlineLevel(block: Block) {
  if (block.kind !== 'section_heading') return 2;
  const title = (block.text_original || block.section_title).replace(/^■\s*/, '').trim();
  return /^([A-Z][A-Z\s/&-]{3,})$/.test(title) || block.order === 2 ? 0 : 1;
}

type OutlineNodeProps = {
  block: Block;
  entities: MethodEntity[];
  index: number;
  active: boolean;
  onClick: () => void;
  onEntityClick: (entity: MethodEntity) => void;
};

export default function OutlineNode({ block, entities, index, active, onClick, onEntityClick }: OutlineNodeProps) {
  const level = getOutlineLevel(block);
  const page = block.page_idx == null ? '' : `P${block.page_idx + 1}`;
  const label = block.kind === 'section_heading' ? (level === 0 ? 'SECTION' : 'SUBSECTION') : block.role_in_narrative || `NODE ${String(index + 1).padStart(2, '0')}`;
  const title = block.kind === 'section_heading' ? block.text_zh || block.text_original || block.section_title : block.one_liner || block.text_zh || block.text_original;
  return (
    <aside className="margin-outline">
      <div
        className={`margin-node level-${level}${active ? ' active' : ''}${block.kind === 'section_heading' ? ' heading' : ''}`}
        style={{ '--outline-indent': `${level * 14}px` } as React.CSSProperties}
        role="button"
        tabIndex={0}
        onClick={onClick}
        onKeyDown={(event) => {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            onClick();
          }
        }}
        title={title}
      >
        <span className="margin-node-meta">{label}{page ? ` · ${page}` : ''}</span>
        <strong>{title}</strong>
        {entities.length > 0 && (
          <span className="margin-node-tags" aria-label="相关方法标签">
            {entities.map((entity) => (
              <button
                key={entity.id}
                type="button"
                title={`将 ${entity.name} 加入论文对话`}
                onClick={(event) => {
                  event.stopPropagation();
                  onEntityClick(entity);
                }}
                onKeyDown={(event) => event.stopPropagation()}
              >
                {entity.name}
              </button>
            ))}
          </span>
        )}
      </div>
    </aside>
  );
}
