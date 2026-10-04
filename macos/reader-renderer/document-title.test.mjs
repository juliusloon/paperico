import {test} from 'node:test';
import assert from 'node:assert/strict';
import {duplicateTitleIds} from './document-title.mjs';
const paper = {title:'Activity-cliffawareness enables robust graph learning',title_zh:'活性悬崖感知实现稳健图学习'};
const block = (id,text,kind='section_heading',page=0) => ({id,text_original:text,kind,page_idx:page});

test('front title duplicates match line breaks, typography and Chinese spacing', () => {
  const blocks = [block('metadata','Article','paragraph'),block('en','**Activity–cliffawareness enables robust\ngraph learning**'),block('zh','活性悬崖感知 实现稳健图学习'),block('abstract','Abstract'),block('body',paper.title)];
  assert.deepEqual([...duplicateTitleIds(paper,blocks)],['en','zh']);
});
test('standalone title matching preserves prose, section headings and late references', () => {
  const blocks = [block('mention',`We study ${paper.title}.`,'paragraph'),block('intro','1 Introduction'),block('later',paper.title),block('methods','Methods')];
  assert.equal(duplicateTitleIds(paper,blocks).size,0);
  assert.equal(duplicateTitleIds(paper,[block('late',paper.title,'section_heading',3)]).size,0);
  assert.equal(duplicateTitleIds({},[block('empty','')]).size,0);
});
test('substantive opening summary ends front-matter matching without an abstract heading', () => {
  const blocks = [block('title',paper.title),block('summary','Scientific prose '.repeat(20),'paragraph'),block('later',paper.title)];
  assert.deepEqual([...duplicateTitleIds(paper,blocks)],['title']);
});
