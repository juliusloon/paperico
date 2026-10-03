import {renderMarkdown} from './markdown.mjs';
import {attachAnnotationEditor} from './annotations.mjs';
let annotationViews = new Map(), annotations = {};

let currentPaper = '', blocks = [], rowMap = new Map(), style = {}, initialProgress = 0;
const send = message => window.webkit?.messageHandlers.reader?.postMessage({...message, paperId: currentPaper});
const element = (tag, className, text) => {
  const node = document.createElement(tag); node.className = className;
  if (text != null) node.textContent = text;
  return node;
};
function rich(source, className = '') {
  const node = element('div', `rich ${className}`); node.innerHTML = renderMarkdown(source); return node;
}
function safeTable(source) {
  const parsed = new DOMParser().parseFromString(source, 'text/html');
  const allowed = new Set(['TABLE','THEAD','TBODY','TFOOT','TR','TD','TH','CAPTION','SUP','SUB','B','I','EM','STRONG','BR']);
  function clean(node) {
    if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.textContent);
    if (node.nodeType !== Node.ELEMENT_NODE || !allowed.has(node.tagName)) return document.createTextNode('');
    const result = document.createElement(node.tagName.toLowerCase());
    for (const attr of ['colspan','rowspan']) {
      const value = node.getAttribute(attr);
      if (value && /^\d{1,3}$/.test(value)) result.setAttribute(attr, value);
    }
    result.append(...Array.from(node.childNodes, clean)); return result;
  }
  const wrapper = element('div','table-scroll');
  const table = parsed.querySelector('table');
  if (table) wrapper.append(clean(table));
  else wrapper.textContent = '表格数据为空';
  return wrapper;
}
function outline(block, index, entities, entry) {
  const node = element('aside','outline');
  const surface = element('div','outline-node');
  const button = element('button','node-jump'); button.type = 'button';
  const heading = block.kind === 'section_heading';
  if (heading) surface.classList.add('heading');
  surface.dataset.level = String(entry?.level ?? (heading ? 1 : 2));
  const role = heading ? (entry?.level > 1 ? '小节' : '章节') : block.role_in_narrative || `NODE ${index + 1}`;
  surface.append(element('span','node-meta',role + (block.page_idx == null ? '' : ` · P${block.page_idx + 1}`)));
  const generatedTitle = entry?.title || (heading ? block.text_zh || block.text_original || block.section_title : block.one_liner || block.text_zh || block.text_original);
  const title = element('strong','',generatedTitle); button.append(title);
  button.addEventListener('click', () => jump(block.id)); surface.append(button); node.append(surface);
  const chips = element('div','entity-chips');
  for (const id of block.entity_refs ?? []) {
    const entity = entities.get(id); if (!entity) continue;
    const chip = element('button','entity-chip',entity.name); chip.type = 'button';
    chip.addEventListener('click', () => send({type:'entity',id,blockId:block.id})); chips.append(chip);
  }
  node.append(chips);
  annotationViews.set(block.id,attachAnnotationEditor(node,block.id,generatedTitle,title,annotations[block.id],send));
  return node;
}
function content(block) {
  const cell = element('div','content');
  if (block.kind === 'section_heading') {
    const section = element('section','section-heading'); section.append(element('span','section-mark','§'));
    const heading = element('div','');
    heading.append(rich(block.text_original || block.section_title,'original heading-original'));
    if (block.text_zh) heading.append(rich(block.text_zh,'translation heading-translation'));
    section.append(heading); cell.append(section); return cell;
  }
  if (['figure','table'].includes(block.kind)) {
    const figure = element('figure','paper-figure');
    if (block.kind === 'table' && block.table_html) figure.append(safeTable(block.table_html));
    else if (block.image_path) {
      const image = element('img','paper-image'); image.src = `paperico-image://block/${encodeURIComponent(block.id)}`;
      image.alt = block.caption_zh || block.caption_original || '论文图表'; image.loading = 'lazy';
      image.addEventListener('click', () => send({type:'figure',blockId:block.id}));
      image.addEventListener('load',scheduleProgress); figure.append(image);
    }
    const caption = element('figcaption','');
    if (block.caption_original) caption.append(rich(block.caption_original,'original'));
    if (block.caption_zh || block.text_zh) caption.append(rich(block.caption_zh || block.text_zh,'translation'));
    figure.append(caption);
    if (block.core_takeaways?.length) {
      const aside = element('aside','takeaways'); aside.append(element('strong','','图表要点'));
      for (const item of block.core_takeaways) aside.append(rich(item)); figure.append(aside);
    }
    cell.append(figure); return cell;
  }
  if (block.kind === 'equation') {
    const equation = element('div','paper-equation');
    const latex = (block.latex || '').trim().replace(/^\$\$|\$\$$/g,'');
    equation.append(rich(`$$\n${latex}\n$$`));
    if (block.plain_explanation) equation.append(rich(block.plain_explanation,'explanation'));
    cell.append(equation); return cell;
  }
  const paragraph = element('div','paragraph');
  if (block.text_original) paragraph.append(rich(block.text_original,'original'));
  if (block.text_zh) paragraph.append(rich(block.text_zh,'translation'));
  cell.append(paragraph); return cell;
}
window.papericoLoad = payload => {
  const paper = payload.paper; currentPaper = paper.id;
  annotations = payload.annotations ?? {}; annotationViews.clear();
  const excluded = new Set(payload.excluded_block_ids ?? []);
  blocks = payload.blocks.map(block => excluded.has(block.id)
    ? {...block,text_zh:'',caption_zh:'',plain_explanation:'',core_takeaways:[]} : block);
  initialProgress = payload.progress || 0; rowMap.clear();
  window.getSelection()?.removeAllRanges(); send({type:'selectionChanged'});
  const entities = new Map(payload.entities.map(x => [x.id,x]));
  const outlines = new Map((payload.outline_entries ?? []).map(x => [x.block_id, x]));
  const lastOutlineId = [...outlines.keys()].at(-1);
  const article = document.getElementById('paper'); article.replaceChildren();
  const row = element('div','document-row header-row');
  const label = element('aside','outline-title');
  label.append(element('span','','OUTLINE'), element('strong','','论文逻辑链'),element('small','',`${outlines.size} 个节点`));
  const header = element('header','content paper-header');
  header.append(element('span','document-label','RESEARCH ARTICLE'),element('h1','',paper.title || paper.original_file_name || '未命名论文'));
  if (paper.title_zh && paper.title_zh !== paper.title) header.append(element('p','',paper.title_zh));
  header.append(element('div','author-line',(paper.authors?.slice(0,6).join(' · ') || paper.original_file_name) + (paper.year ? ` · ${paper.year}` : '')));
  row.append(label,header); article.append(row);
  for (const [index,block] of blocks.entries()) {
    const row = element('div',`document-row kind-${block.kind}`); row.id = `block-${block.id}`; row.dataset.blockId = block.id;
    row.dataset.level = String(outlines.get(block.id)?.level ?? (block.kind === 'section_heading' ? 1 : 2));
    const entry = outlines.get(block.id);
    if (excluded.has(block.id)) row.classList.add('outside-body');
    if (block.id === lastOutlineId) row.classList.add('outline-last');
    row.append(entry ? outline(block,index,entities,entry) : element('aside','outline empty'),content(block));
    rowMap.set(block.id,row); article.append(row);
  }
  const footer = element('div','document-row footer-row'); footer.append(element('span',''),element('footer','content','END OF PAPER')); article.append(footer);
  applyStyle(style);
  document.fonts.ready.then(() => requestAnimationFrame(() => {
    window.scrollTo(0, Math.max(0, document.documentElement.scrollHeight - innerHeight) * initialProgress / 100);
    scheduleProgress(); send({type:'loaded',nodes:blocks.length,math:document.querySelectorAll('.katex').length,superscripts:document.querySelectorAll('sup').length});
  }));
};
function applyStyle(next) {
  style = next; const root = document.documentElement;
  for (const [name,value] of Object.entries(next.colors ?? {})) root.style.setProperty(`--${name}`,value);
  root.style.setProperty('--reading-size',`${next.fontSize || 18}px`);
  root.style.setProperty('--outline-width',`${next.outlineWidth || 0}px`);
  root.classList.toggle('outline-hidden',!next.outlineWidth || next.compact);
  root.style.colorScheme = next.dark ? 'dark' : 'light';
  root.dataset.theme = next.dark ? 'dark' : 'light';
  root.dataset.mode = next.mode || 'bilingual';
}
window.papericoAnnotations = next => { annotations = next; for (const [id,view] of annotationViews) view.update(next[id]); };
window.papericoStyle = next => {
  // Keep the nearest paragraph in view when changing typography or language.
  const anchor = [...rowMap.values()].find(x => x.getBoundingClientRect().bottom > 70);
  const before = anchor?.getBoundingClientRect().top;
  applyStyle(next);
  if (anchor && before != null) window.scrollBy(0,anchor.getBoundingClientRect().top - before);
  scheduleProgress(); scheduleSelection();
};
function jump(id,centered = false) {
  const row = rowMap.get(id); if (!row) return;
  row.scrollIntoView({block:centered ? 'center':'start',behavior:'auto'});
  row.classList.remove('flash'); void row.offsetWidth; row.classList.add('flash');
  scheduleProgress(); send({type:'jump',blockId:id});
}
window.papericoJump = jump;
let scheduled = false, lastSent = 0;
function scheduleProgress() {
  if (scheduled) return; scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    if (performance.now() - lastSent < 90) { setTimeout(scheduleProgress,90); return; }
    lastSent = performance.now();
    const max = Math.max(0,document.documentElement.scrollHeight - innerHeight);
    const progress = max ? Math.min(100,Math.max(0,scrollY / max * 100)) : 0;
    const y = Math.min(180,innerHeight * .25);
    let active = '',distance = Infinity;
    for (const [id,row] of rowMap) {
      const d = Math.abs(row.getBoundingClientRect().top - y);
      if (d < distance) { distance = d; active = id; }
    }
    document.querySelector('.outline-node.active')?.classList.remove('active');
    rowMap.get(active)?.querySelector('.outline-node')?.classList.add('active');
    send({type:'progress',progress,blockId:active});
  });
}
window.addEventListener('scroll',scheduleProgress,{passive:true});
window.addEventListener('resize',scheduleProgress);
// The selection action is rendered by SwiftUI, so both document surfaces use
// the same system Liquid Glass button. Send viewport coordinates after every
// selection, scroll, resize and keyboard adjustment.
let selectionScheduled = false, pointerSelecting = false;
function scheduleSelection() {
  if (selectionScheduled) return;
  selectionScheduled = true;
  requestAnimationFrame(() => {
    selectionScheduled = false;
    if (pointerSelecting) { send({type:'selectionChanged'}); return; }
    const selection = window.getSelection();
    const text = selection?.toString().trim();
    if (document.activeElement?.matches('.node-editor') || !text || !selection.rangeCount) { send({type:'selectionChanged'}); return; }
    const origin = selection.anchorNode?.parentElement?.closest('[data-block-id]');
    if (!origin) { send({type:'selectionChanged'}); return; }
    const rects = [...selection.getRangeAt(0).getClientRects()];
    const visible = rects.filter(rect => rect.bottom > 76 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth);
    if (!visible.length) { send({type:'selectionChanged'}); return; }
    const rect = visible.at(-1);
    const x = Math.max(0,rect.left), y = Math.max(76,rect.top);
    send({type:'selectionChanged',blockId:origin.dataset.blockId,snippet:text.slice(0,6000),
          rect:{x,y,width:Math.max(1,Math.min(innerWidth,rect.right)-x),height:Math.max(1,Math.min(innerHeight,rect.bottom)-y)}});
  });
}
window.papericoClearSelection = () => { window.getSelection()?.removeAllRanges(); send({type:'selectionChanged'}); };
document.addEventListener('selectionchange',scheduleSelection);
// Selection changes during a drag must not expose a native button under the pointer.
document.addEventListener('pointerdown', event => {
  if (event.button !== 0) return;
  pointerSelecting = true;
  send({type:'selectionChanged'});
}, {capture:true});
window.addEventListener('pointerup', event => {
  if (event.button !== 0) return;
  pointerSelecting = false;
  scheduleSelection();
}, {capture:true});
for (const event of ['pointercancel','blur']) window.addEventListener(event, () => {
  pointerSelecting = false;
  window.getSelection()?.removeAllRanges();
  send({type:'selectionChanged'});
});
document.addEventListener('keyup',scheduleSelection);
window.addEventListener('scroll',scheduleSelection,{passive:true});
window.addEventListener('resize',scheduleSelection);
