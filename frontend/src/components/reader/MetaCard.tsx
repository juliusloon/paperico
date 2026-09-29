import { Clock3, FileText, Gauge, Sparkles } from 'lucide-react';
import { useReaderStore } from '../../stores';

export default function MetaCard() {
  const detail = useReaderStore((state) => state.paper);
  if (!detail) return null;
  const { paper, entities, blocks } = detail;
  const characterCount = blocks.reduce((sum, block) => sum + (block.text_original?.length || 0), 0);
  const readingMinutes = Math.max(1, Math.round(characterCount / 1100));

  return (
    <div className="meta-card-body">
      <div className="meta-title-row">
        <div>
          <span className="meta-type">{paper.venue || 'RESEARCH PAPER'}</span>
          <h2>{paper.title || paper.original_file_name || '未命名论文'}</h2>
        </div>
      </div>
      {paper.title_zh && paper.title_zh !== paper.title && <p className="meta-title-zh">{paper.title_zh}</p>}
      {paper.authors?.length > 0 && <p className="meta-authors">{paper.authors.slice(0, 6).join(' · ')}{paper.authors.length > 6 ? ' 等' : ''}</p>}

      <div className="meta-stats">
        <span><Clock3 size={11} /><b>{readingMinutes}</b> 分钟</span>
        <span><FileText size={11} /><b>{blocks.length}</b> 节点</span>
        <span><Gauge size={11} /><b>{paper.difficulty_estimate || '待评估'}</b></span>
      </div>

      {paper.domain_tags?.length > 0 && <div className="meta-tags">{paper.domain_tags.map((tag) => <span key={tag}>{tag}</span>)}</div>}

      {paper.tldr && <section className="meta-summary featured"><header><Sparkles size={11} />一句话总结</header><p>{paper.tldr}</p></section>}
      {paper.narrative_summary && <section className="meta-summary"><header>全文主线</header><p>{paper.narrative_summary}</p></section>}
      {paper.contributions?.length > 0 && <section className="meta-summary"><header>核心贡献</header><ol>{paper.contributions.map((item) => <li key={item}>{item}</li>)}</ol></section>}

      {entities.length > 0 && (
        <section className="meta-entities">
          <header><span>方法与实体</span><small>{entities.length}</small></header>
          <div>{entities.slice(0, 18).map((entity) => (
            <button key={entity.id} title={entity.definition_zh || entity.category} onClick={() => {
              useReaderStore.getState().highlightEntities([entity.id]);
              const firstBlock = entity.block_refs?.[0];
              if (firstBlock) document.getElementById(`block-${firstBlock}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }}>{entity.name}</button>
          ))}</div>
        </section>
      )}
    </div>
  );
}
