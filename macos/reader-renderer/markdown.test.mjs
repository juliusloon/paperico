import {test} from 'node:test';
import assert from 'node:assert/strict';
import {renderMarkdown} from './markdown.mjs';

test('MinerU authors and citations preserve raised superscripts', () => {
  const html = renderMarkdown('Author<sup>1,2</sup> and potency<sup>19,27</sup>.');
  assert.match(html, /Author<sup>1,2<\/sup>/);
  assert.match(html, /potency<sup>19,27<\/sup>/);
  assert.doesNotMatch(html, /&lt;sup/);
});
test('subscripts and formatted text remain readable', () => {
  assert.equal(renderMarkdown('H<sub>2</sub>O and **bold**.'), '<p>H<sub>2</sub>O and <strong>bold</strong>.</p>');
});
test('inline math renders fractions and retains a semantic MathML representation', () => {
  const html = renderMarkdown('Ratio $\\frac{x_j}{x_i}=10^{\\mathrm{cliff}}$.');
  assert.match(html, /class="katex"/);
  assert.match(html, /<mfrac>/);
  assert.match(html, /<msup>/);
  assert.doesNotMatch(html, /katex-error/);
});
test('display math supports aligned equations and equation numbers', () => {
  const html = renderMarkdown('$$\n\\begin{aligned}y_i&=-\\log_{10}(x_i\\times10^{-9})\\\\y_j&=-\\log_{10}(x_j\\times10^{-9})\\end{aligned}\\tag{1}\n$$');
  assert.match(html, /katex-display/);
  assert.match(html, /mtable/);
  assert.doesNotMatch(html, /katex-error/);
});
test('MinerU TeX delimiters render both inline and display math', () => {
  const html = renderMarkdown('Value \\(x_i^2\\) and\n\\[\\sum_{i=1}^{n} x_i\\]');
  assert.equal((html.match(/class="katex"/g) ?? []).length, 2);
  assert.match(html, /katex-display/);
});
test('chemistry notation is rendered locally', () => {
  const html = renderMarkdown('$\\ce{H2O -> H+ + OH-}$');
  assert.match(html, /class="katex"/);
  assert.doesNotMatch(html, /katex-error/);
});
test('paper HTML cannot inject active tags or attributes', () => {
  const html = renderMarkdown('<script>alert(1)</script>\n\n<img src="https://example.com/tracker" onerror="alert(1)">\n\nSafe<sup onclick="alert(1)">1</sup>.');
  assert.doesNotMatch(html, /<script|<img|onerror=|onclick=/);
});
test('external images and unsafe links cannot create background requests', () => {
  const html = renderMarkdown('![figure](https://example.com/tracker) [bad](javascript:alert) [good](https://example.com/paper)');
  assert.doesNotMatch(html, /<img|href="javascript:/);
  assert.match(html, /figure/);
  assert.match(html, /href="https:\/\/example.com\/paper"/);
});
