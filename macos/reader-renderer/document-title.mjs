// Match standalone front-matter titles only; do not remove source data or
// fuzzy-match scientific prose that happens to mention the article title.
function normalizedTitle(source = '') {
  return source.normalize('NFKC')
    .replace(/<[^>]*>/g,'')
    .replace(/\[([^\]]+)\]\([^)]+\)/g,'$1')
    .replace(/&(?:amp|#38|#x26);/gi,'&')
    .replace(/&(?:nbsp|#160|#xa0);/gi,' ')
    .toLocaleLowerCase('en').replace(/[^\p{L}\p{N}]/gu,'');
}

export function duplicateTitleIds(paper, blocks) {
  const titles = new Set([paper.title,paper.title_zh].map(x => normalizedTitle(x)).filter(x => x.length >= 8));
  const duplicates = new Set();
  if (!titles.size) return duplicates;
  for (const [index, block] of blocks.entries()) {
    if (index >= 30 || (block.page_idx ?? 0) > 1) break;
    if (!['section_heading','paragraph'].includes(block.kind)) continue;
    const source = block.text_original || block.text_zh || block.section_title || '';
    const normalized = normalizedTitle(source);
    if (titles.has(normalized)) { duplicates.add(block.id); continue; }
    const label = normalized.replace(/^\d+/,'');
    if (block.kind === 'section_heading' && /^(abstract|summary|introduction|background|methods|results|摘要|概要|引言|绪论|背景|方法|结果)$/.test(label)) break;
    if (block.kind === 'paragraph' && source.length >= 220) break;
  }
  return duplicates;
}
