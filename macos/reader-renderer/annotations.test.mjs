import {test} from 'node:test';
import assert from 'node:assert/strict';
import {attachAnnotationEditor, wrapSelection, annotationSize} from './annotations.mjs';
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
  closest(selector) {
    for (let element = this; element; element = element.parentElement) {
      if ((element.className || '').split(' ').includes(selector.slice(1))) return element;
    }
    return null;
  }
  setPointerCapture(id) { this.capturedPointer = id; }
  hasPointerCapture(id) { return this.capturedPointer === id; }
  releasePointerCapture() { this.capturedPointer = null; }
  getBoundingClientRect() { return {x:8,y:220,width:240,height:100}; }
  focus() {}
  setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
  remove() {
    if (!this.parentElement) return;
    this.parentElement.children = this.parentElement.children.filter(child => child !== this);
    this.parentElement = null;
  }
  after(element) {
    if (!this.parentElement) return;
    const siblings = this.parentElement.children;
    element.parentElement = this.parentElement;
    siblings.splice(siblings.indexOf(this)+1,0,element);
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
function editorFor(node) { return node.children.at(-1).children[0].children[0]; }

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


test('corner resizing stays within the outline and preserves a usable input size', () => {
  assert.deepEqual(annotationSize(240,100,200,40,290),{width:290,height:140});
  assert.deepEqual(annotationSize(240,100,-500,-500,290),{width:120,height:64});
  assert.deepEqual(annotationSize(240,100,20,40,90),{width:90,height:140});
});

test('invisible editor corner resizes with capture and stops after cancellation', () => withFakeEditor(() => {
  const events = [], {node} = makeEditor('resize-note',events);
  clickNote(node);
  const box = node.children.at(-1), surface = box.children[0], corner = surface.children[1];
  box.clientWidth = 290;
  const eventCount = events.length;
  assert.equal(corner.children.length,0);
  corner.dispatch('pointerdown',{button:0,pointerId:1,clientX:240,clientY:100});
  assert.equal(corner.hasPointerCapture(1),true);
  corner.dispatch('pointermove',{pointerId:1,clientX:300,clientY:170});
  assert.deepEqual(surface.style,{width:'290px',height:'170px'});
  corner.dispatch('pointercancel',{pointerId:1});
  assert.equal(corner.hasPointerCapture(1),false);
  corner.dispatch('pointermove',{pointerId:1,clientX:140,clientY:50});
  assert.deepEqual(surface.style,{width:'290px',height:'170px'});
  assert.equal(events.length,eventCount);
  window.papericoFinishAnnotation(false);
}));

test('native glass editor reserves layout, updates drafts, resizes and detaches safely', () => withFakeEditor(() => {
  const previousRAF = globalThis.requestAnimationFrame, previousCancel = globalThis.cancelAnimationFrame;
  const previousObserver = globalThis.ResizeObserver;
  let nextFrame = 0; const frames = new Map(), listeners = new Map();
  globalThis.requestAnimationFrame = callback => { frames.set(++nextFrame,callback); return nextFrame; };
  globalThis.cancelAnimationFrame = id => frames.delete(id);
  globalThis.ResizeObserver = class { observe() {} disconnect() { this.disconnected = true; } };
  window.addEventListener = (type,callback) => listeners.set(type,callback);
  window.removeEventListener = type => listeners.delete(type);
  window.papericoNativeAnnotations = true;
  function flush() { const pending = [...frames.values()]; frames.clear(); for (const frame of pending) frame(); }
  try {
    const events = [], {node} = makeEditor('native',events);
    clickNote(node); flush();
    const box = node.children.at(-1), surface = box.children[0]; box.clientWidth = 290;
    assert.equal(surface.style.height,'96px');
    assert.deepEqual(events.find(event => event.type === 'annotationEditor').rect,{x:8,y:220,width:240,height:100});
    assert.equal(events.find(event => event.type === 'annotationEditor').fontSize,14);
    const staleInput = window.papericoAnnotationInput;
    assert.equal(staleInput('other','note','wrong','commit'),false);
    assert.equal(staleInput('native','note','记录依据','draft'),true);
    assert.equal(events.at(-1).phase,'draft');
    assert.equal(window.papericoResizeAnnotation('native','note',400,150),true);
    assert.deepEqual(surface.style,{width:'290px',height:'150px'});
    listeners.get('scroll')(); flush();
    assert.equal(events.at(-1).value,'记录依据');
    assert.equal(staleInput('native','note','记录依据','commit'),true);
    assert.equal(events.some(event => event.phase === 'commit' && event.value === '记录依据'),true);
    assert.equal(window.papericoAnnotationInput,null);
    assert.equal(window.papericoResizeAnnotation,null);
    assert.equal(listeners.size,0);
    assert.equal(frames.size,0);
    assert.equal(staleInput('native','note','不能再写入','draft'),false);
    assert.equal(events.some(event => event.type === 'annotationEditor' && event.active === false),true);
  } finally {
    if (previousRAF === undefined) delete globalThis.requestAnimationFrame; else globalThis.requestAnimationFrame = previousRAF;
    if (previousCancel === undefined) delete globalThis.cancelAnimationFrame; else globalThis.cancelAnimationFrame = previousCancel;
    if (previousObserver === undefined) delete globalThis.ResizeObserver; else globalThis.ResizeObserver = previousObserver;
  }
}));

test('native entry actions remain mounted when entering their overlay and clear on leaving', () => withFakeEditor(() => {
  window.papericoNativeAnnotations = true;
  const events = [], {node} = makeEditor('native-actions',events);
  node.dispatch('pointerenter');
  assert.deepEqual(events.at(-1),{type:'annotationActions',blockId:'native-actions',active:true,rect:{x:8,y:220,width:66,height:30}});
  const count = events.length;
  node.dispatch('pointerleave',{clientX:20,clientY:235});
  assert.equal(events.length,count);
  node.dispatch('pointerleave',{clientX:200,clientY:235});
  assert.equal(events.at(-1).active,false);
  assert.equal(window.papericoReportAnnotationActions,null);
}));

test('native title editor inherits the visible node font size', () => withFakeEditor(() => {
  const savedRAF = globalThis.requestAnimationFrame, savedCancel = globalThis.cancelAnimationFrame;
  const savedObserver = globalThis.ResizeObserver, savedStyle = globalThis.getComputedStyle;
  const frames = [];
  globalThis.requestAnimationFrame = callback => { frames.push(callback); return frames.length; };
  globalThis.cancelAnimationFrame = () => {};
  globalThis.ResizeObserver = class { observe() {} disconnect() {} };
  globalThis.getComputedStyle = () => ({fontSize:'13.5px',fontWeight:'450'});
  window.addEventListener = () => {}; window.removeEventListener = () => {}; window.papericoNativeAnnotations = true;
  try {
    const node = document.createElement('aside'), parent = document.createElement('button'), title = document.createElement('strong'), events = [];
    parent.append(title); node.append(parent);
    const view = attachAnnotationEditor(node,'title','原标题',title,{},value => events.push(value));
    view.begin('title'); frames.shift()();
    const payload = events.find(event => event.type === 'annotationEditor');
    assert.equal(payload.fontSize,13.5); assert.equal(payload.fontWeight,450);
    assert.equal(window.papericoFinishAnnotation(false),true);
  } finally {
    if (savedRAF === undefined) delete globalThis.requestAnimationFrame; else globalThis.requestAnimationFrame = savedRAF;
    if (savedCancel === undefined) delete globalThis.cancelAnimationFrame; else globalThis.cancelAnimationFrame = savedCancel;
    if (savedObserver === undefined) delete globalThis.ResizeObserver; else globalThis.ResizeObserver = savedObserver;
    globalThis.getComputedStyle = savedStyle;
  }
}));
