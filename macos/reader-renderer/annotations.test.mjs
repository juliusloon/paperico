import {test} from 'node:test';
import assert from 'node:assert/strict';
import {attachAnnotationEditor, wrapSelection} from './annotations.mjs';
import {renderMarkdown} from './markdown.mjs';

class FakeElement {
  constructor(tag) {
    this.tagName = tag.toUpperCase(); this.children = []; this.parentElement = null;
    this.listeners = new Map(); this.classList = {add() {}, remove() {}};
    this.style = {}; this.hidden = false; this.value = '';
    this.selectionStart = 0; this.selectionEnd = 0;
  }
  append(...children) {
    for (const child of children) { child.parentElement = this; this.children.push(child); }
  }
  addEventListener(type, listener) { this.listeners.set(type, listener); }
  dispatch(type, event = {}) {
    return this.listeners.get(type)?.({...event, preventDefault() {}, stopPropagation() {}});
  }
  setAttribute() {}
  focus() {}
  setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  remove() {
    if (!this.parentElement) return;
    this.parentElement.children = this.parentElement.children.filter(child => child !== this);
    this.parentElement = null;
  }
}

function withFakeEditor(callback) {
  const previousDocument = globalThis.document;
  const previousWindow = globalThis.window;
  const previousGetComputedStyle = globalThis.getComputedStyle;
  globalThis.document = {createElement: tag => new FakeElement(tag)};
  globalThis.window = {};
  globalThis.getComputedStyle = () => ({font: '14px sans-serif'});
  try { return callback(); }
  finally {
    if (previousDocument === undefined) delete globalThis.document;
    else globalThis.document = previousDocument;
    if (previousWindow === undefined) delete globalThis.window;
    else globalThis.window = previousWindow;
    if (previousGetComputedStyle === undefined) delete globalThis.getComputedStyle;
    else globalThis.getComputedStyle = previousGetComputedStyle;
  }
}

function makeEditor(id, events) {
  const node = document.createElement('aside');
  const titleParent = document.createElement('div');
  const title = document.createElement('strong'); titleParent.append(title);
  attachAnnotationEditor(node, id, `Node ${id}`, title, {}, message => events.push(message));
  return {node, title};
}

function clickNote(node) { node.children[0].children[1].dispatch('click'); }
function editorFor(node) { return node.children.at(-1).children[0]; }

function formatSelected(editor, key) {
  editor.value = 'abc'; editor.selectionStart = 0; editor.selectionEnd = 3;
  assert.equal(window.papericoFormatNodeNote(key), true);
}

test('note shortcuts retain Unicode selection and combine styles', () => {
  const bold = wrapSelection('证据 🔬 发现', 3, 5, '**');
  assert.equal(bold.value, '证据 **🔬** 发现');
  assert.equal(bold.value.slice(bold.start, bold.end), '🔬');
  const highlight = wrapSelection('**重点**', 0, 6, '==');
  assert.equal(renderMarkdown(highlight.value), '<p><mark><strong>重点</strong></mark></p>');
});

test('note highlights preserve bold and italic while escaping unsafe content', () => {
  assert.equal(renderMarkdown('==**重点** 与 *依据*=='), '<p><mark><strong>重点</strong> 与 <em>依据</em></mark></p>');
  assert.equal(renderMarkdown('==x < y=='), '<p><mark>x &lt; y</mark></p>');
  assert.doesNotMatch(renderMarkdown('==<script>alert(1)</script>=='), /<script/);
});

test('unfinished highlights and code remain unchanged', () => {
  assert.equal(renderMarkdown('==未完成'), '<p>==未完成</p>');
  assert.equal(renderMarkdown('`==code==`'), '<p><code>==code==</code></p>');
  assert.equal(renderMarkdown('==第一行\n第二行=='), '<p>==第一行\n第二行==</p>');
});

test('annotation node switching keeps active shortcut formatting and drafts', () => withFakeEditor(() => {
  const firstEvents = [], secondEvents = [];
  const first = makeEditor('first', firstEvents); const second = makeEditor('second', secondEvents);
  clickNote(first.node);
  const firstEditor = editorFor(first.node);
  for (const [key, marker] of [['b', '**'], ['i', '*'], ['h', '==']]) {
    formatSelected(firstEditor, key);
    assert.equal(firstEditor.value, `${marker}abc${marker}`);
  }
  clickNote(second.node);
  assert.equal(firstEvents.some(event => event.phase === 'commit' && event.blockId === 'first'), true);
  const secondEditor = editorFor(second.node);
  formatSelected(secondEditor, 'h');
  assert.equal(secondEditor.value, '==abc==');
  assert.equal(secondEvents.some(event => event.phase === 'draft' && event.blockId === 'second'), true);
  assert.equal(window.papericoFinishAnnotation(false), true);
  assert.equal(window.papericoFinishAnnotation, null);
  assert.equal(window.papericoFormatNodeNote, null);
}));

test('stale annotation close cannot clear a newer formatter', () => withFakeEditor(() => {
  const firstEvents = [], secondEvents = [];
  const first = makeEditor('first', firstEvents); const second = makeEditor('second', secondEvents);
  clickNote(first.node);
  const staleFinish = window.papericoFinishAnnotation;
  const staleFormatter = window.papericoFormatNodeNote;
  window.papericoFinishAnnotation = () => true;
  clickNote(second.node);
  const currentFinish = window.papericoFinishAnnotation;
  const currentFormatter = window.papericoFormatNodeNote;
  assert.notEqual(currentFormatter, staleFormatter);
  const firstEventCount = firstEvents.length;
  staleFinish(false);
  assert.equal(firstEvents.slice(firstEventCount).some(event => event.type === 'annotationFocus'), false);
  assert.equal(window.papericoFinishAnnotation, currentFinish);
  assert.equal(window.papericoFormatNodeNote, currentFormatter);
  const secondEditor = editorFor(second.node);
  formatSelected(secondEditor, 'b');
  assert.equal(secondEditor.value, '**abc**');
  assert.equal(secondEvents.some(event => event.phase === 'draft' && event.blockId === 'second'), true);
}));

test('visible save and cancel actions commit or discard node note drafts', () => withFakeEditor(() => {
  const events = [], {node} = makeEditor('glass-note',events);
  clickNote(node);
  editorFor(node).value = '保存的证据';
  node.children.at(-1).children[1].children[0].dispatch('click');
  assert.equal(events.some(event => event.phase === 'commit' && event.value === '保存的证据'),true);
  clickNote(node);
  editorFor(node).value = '取消的草稿';
  node.children.at(-1).children[1].children[1].dispatch('click');
  assert.equal(events.at(-2).phase,'cancel');
  assert.equal(events.some(event => event.phase === 'commit' && event.value === '取消的草稿'),false);
  assert.equal(window.papericoFinishAnnotation,null);
}));
