import test from 'node:test';
import assert from 'node:assert/strict';

// Exercise the actual renderer listeners with a deterministic viewport and RAF.
const documentEvents = new Map(), windowEvents = new Map(), frames = [], messages = [];
const listen = map => (name, callback) => {
  if (!map.has(name)) map.set(name, []);
  map.get(name).push(callback);
};
const dispatch = (map, name, event = {}) => map.get(name)?.forEach(callback => callback(event));
const flush = () => { while (frames.length) frames.shift()(); };
let selected = 'final selected text';
let rect = {left:100, top:200, right:300, bottom:225};
globalThis.innerWidth = 700;
globalThis.innerHeight = 800;
globalThis.scrollY = 0;
globalThis.requestAnimationFrame = callback => frames.push(callback);
globalThis.document = {
  compatMode:'CSS1Compat',
  documentElement:{scrollHeight:1600},
  querySelector:() => null,
  addEventListener:listen(documentEvents)
};
globalThis.window = {
  addEventListener:listen(windowEvents),
  webkit:{messageHandlers:{reader:{postMessage:message => messages.push(message)}}},
  getSelection:() => ({
    toString:() => selected, rangeCount: selected ? 1 : 0,
    anchorNode:{parentElement:{closest:() => ({dataset:{blockId:'block-1'}})}},
    getRangeAt:() => ({getClientRects:() => [rect]}),
    removeAllRanges:() => { selected = ''; }
  })
};
await import('./reader.mjs');

test('selection action waits for pointer release and tracks the final visible range', () => {
  dispatch(documentEvents,'selectionchange'); // A frame queued before mouse-down is also suppressed.
  dispatch(documentEvents,'pointerdown',{button:0});
  flush();
  assert.equal(messages.at(-1).snippet, undefined);
  dispatch(documentEvents,'selectionchange');
  flush();
  assert.equal(messages.at(-1).snippet, undefined);
  selected = 'selection on release';
  dispatch(windowEvents,'pointerup',{button:0});
  flush();
  assert.equal(messages.at(-1).snippet,'selection on release');
  assert.equal(messages.at(-1).blockId,'block-1');
  assert.deepEqual(messages.at(-1).rect,{x:100,y:200,width:200,height:25});

  // Keyboard range changes do not need a pointer gesture.
  selected = 'keyboard selection';
  dispatch(documentEvents,'keyup');
  flush();
  assert.equal(messages.at(-1).snippet,selected);

  // Resizing moves the action; offscreen selections dismiss it.
  rect = {left:90,top:220,right:280,bottom:245};
  dispatch(windowEvents,'resize');
  flush();
  assert.deepEqual(messages.filter(x => x.type === 'selectionChanged').at(-1).rect,{x:90,y:220,width:190,height:25});
  rect = {left:90,top:-50,right:280,bottom:-25};
  dispatch(documentEvents,'selectionchange');
  flush();
  assert.equal(messages.at(-1).snippet,undefined);
});

test('cancelled pointer gestures and lost focus cannot leave a stale action', () => {
  rect = {left:100,top:200,right:300,bottom:225};
  for (const event of ['pointercancel','blur']) {
    selected = 'unfinished selection';
    dispatch(documentEvents,'pointerdown',{button:0});
    dispatch(windowEvents,event);
    flush();
    assert.equal(messages.at(-1).snippet,undefined);
    selected = 'new keyboard selection';
    dispatch(documentEvents,'keyup');
    flush();
    assert.equal(messages.at(-1).snippet,selected);
  }
});
