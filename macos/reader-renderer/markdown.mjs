import {unified} from 'unified';
import remarkParse from 'remark-parse';
import remarkMath from 'remark-math';
import remarkRehype from 'remark-rehype';
import rehypeKatex from 'rehype-katex';
import 'katex/contrib/mhchem';

// Only superscript/subscript HTML is accepted from paper Markdown. Everything
// else stays escaped or is discarded by remark-rehype; raw HTML never executes.
function scripts() {
  return tree => {
    function visit(node) {
      if (!node.children) return;
      const children = node.children;
      for (let i = 0; i < children.length; i++) {
        const child = children[i];
        const tag = child.type === 'html' && /^<(sup|sub)>$/i.exec(child.value);
        if (tag) {
          const close = children.findIndex((x, j) => j > i && x.type === 'html' && x.value.toLowerCase() === `</${tag[1].toLowerCase()}>`);
          if (close > i) {
            const group = {type: 'script', data: {hName: tag[1].toLowerCase()}, children: children.slice(i + 1, close)};
            children.splice(i, close - i + 1, group);
          }
        }
        visit(children[i]);
      }
    }
    visit(tree);
  };
}

// Theme-coloured highlights for node notes; text remains escaped by the serializer.
function highlights() {
  return tree => {
    function visit(node) {
      if (!node.children || ['code','inlineCode','math','inlineMath'].includes(node.type)) return;
      node.children.forEach(visit);
      // Delimiters can surround formatted inline children: ==**bold**==.
      const tokens = node.children.flatMap(child => child.type === 'text'
        ? child.value.split(/(==)/g).filter(Boolean).map(value => ({type:'text',value})) : [child]);
      const result = [];
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].type !== 'text' || tokens[i].value !== '==') { result.push(tokens[i]); continue; }
        let close = i + 1;
        while (close < tokens.length && !(tokens[close].type === 'text' && tokens[close].value === '==')) close++;
        const inner = tokens.slice(i + 1, close);
        if (close < tokens.length && inner.length && !inner.some(x => x.type === 'text' && x.value.includes('\n'))) {
          result.push({type:'highlight',data:{hName:'mark'},children:inner}); i = close;
        } else result.push(tokens[i]);
      }
      node.children = result;
    }
    visit(tree);
  };
}

const processor = unified().use(remarkParse).use(remarkMath).use(scripts).use(highlights)
  .use(remarkRehype).use(rehypeKatex, {throwOnError: false, trust: false, strict: 'ignore'});
export const escapeHTML = text => String(text ?? '').replace(/[&<>"']/g, x => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[x]));
const safeURL = value => /^(https?:|mailto:|#)/i.test(value);
function serialize(node) {
  if (node.type === 'text') return escapeHTML(node.value);
  if (node.type === 'root') return (node.children ?? []).map(serialize).join('');
  if (node.type !== 'element') return '';
  // Markdown images cannot fetch external URLs. Paper figures use a scoped
  // local resource handler supplied by the native app instead.
  if (node.tagName === 'img') return escapeHTML(node.properties?.alt ?? '');
  const attrs = Object.entries(node.properties ?? {}).flatMap(([key, value]) => {
    if (/^on/i.test(key) || ['src','srcSet','id'].includes(key)) return [];
    if (key === 'href' && !safeURL(String(value))) return [];
    const name = {className: 'class', htmlFor: 'for', ariaHidden: 'aria-hidden'}[key] ?? key;
    return [` ${name}="${escapeHTML(Array.isArray(value) ? value.join(' ') : value)}"`];
  }).join('');
  const inner = (node.children ?? []).map(serialize).join('');
  return ['br','hr'].includes(node.tagName) ? `<${node.tagName}${attrs}>` : `<${node.tagName}${attrs}>${inner}</${node.tagName}>`;
}
export function renderMarkdown(source) {
  // MinerU may return both dollar and TeX delimiters.
  source = String(source ?? '').replace(/\\\[([\s\S]*?)\\\]/g, (_, math) => `\n$$\n${math}\n$$\n`).replace(/\\\(([\s\S]*?)\\\)/g, (_, math) => `$${math}$`);
  return serialize(processor.runSync(processor.parse(source)));
}
