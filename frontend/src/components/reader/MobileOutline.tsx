import { useMemo } from 'react';
import { useReaderStore } from '../../stores';
import type { MethodEntity } from '../../api/types';
import OutlineNode from './OutlineNode';

type MobileOutlineProps = {
  onNavigate: (blockId: string) => void;
  onEntityChat: (entity: MethodEntity, blockId: string) => void;
};

/** Full-screen logic-chain outline used as the "逻辑链" tab in the mobile reader. */
export default function MobileOutline({ onNavigate, onEntityChat }: MobileOutlineProps) {
  const { paper, activeBlockId } = useReaderStore();
  const blocks = paper?.blocks || [];
  const entityMap = useMemo(() => new Map((paper?.entities || []).map((entity) => [entity.id, entity])), [paper?.entities]);

  if (!blocks.length) {
    return (
      <div className="mobile-outline-empty">
        <span>论文内容尚未准备好，逻辑目录会在解析完成后出现。</span>
      </div>
    );
  }

  return (
    <div className="mobile-outline">
      <header className="mobile-outline-header">
        <span>OUTLINE</span>
        <strong>论文逻辑目录</strong>
        <small>{blocks.length} 个节点 · 点击节点跳转正文，点击标签加入对话</small>
      </header>
      <div className="mobile-outline-list">
        {blocks.map((block, index) => (
          <OutlineNode
            key={block.id}
            block={block}
            entities={block.entity_refs.map((id) => entityMap.get(id)).filter((entity): entity is MethodEntity => Boolean(entity))}
            index={index}
            active={activeBlockId === block.id}
            onClick={() => onNavigate(block.id)}
            onEntityClick={(entity) => onEntityChat(entity, block.id)}
          />
        ))}
      </div>
    </div>
  );
}
