import {renderMarkdown} from './markdown.mjs';

export function wrapSelection(value, start, end, marker) {
  return {value: value.slice(0,start) + marker + value.slice(start,end) + marker + value.slice(end),
          start: start + marker.length, end: end + marker.length};
}
const markers = {b:'**',i:'*',h:'=='};
export function attachAnnotationEditor(node, id, generatedTitle, titleElement, initial, send) {
  let value = initial || {}, editor = null, editingField = null, detachNative = null;
  const actions = document.createElement('div'); actions.className = 'node-actions';
  const note = document.createElement('div'); note.className = 'node-note rich';
  const icons = {
    title: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l4 4M4 20l4-1L20 7a2.8 2.8 0 0 0-4-4L4 15z"/></svg>',
    note: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 3h12a2 2 0 0 1 2 2v12l-4 4H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM16 21v-4h4M8 8h8M8 12h8"/></svg>'
  };
  for (const [field, label] of [['title','编辑逻辑链'],['note','节点笔记']]) {
    const button = document.createElement('button'); button.type = 'button'; button.className = 'node-glass-button'; button.innerHTML = icons[field];
    button.title = label; button.setAttribute('aria-label',label);
    button.addEventListener('click', event => { event.stopPropagation(); begin(field); }); actions.append(button);
  }
  node.append(actions,note);
  function clearActions() {
    if (window.papericoReportAnnotationActions !== reportActions) return;
    window.papericoReportAnnotationActions = null;
    send({type:'annotationActions',blockId:id,active:false});
  }
  function reportActions() {
    if (!window.papericoNativeAnnotations || editor) { clearActions(); return; }
    const rect = actions.getBoundingClientRect();
    window.papericoReportAnnotationActions = reportActions;
    send({type:'annotationActions',blockId:id,active:true,rect:{x:rect.x,y:rect.y,width:66,height:30}});
  }
  node.addEventListener('pointerenter',reportActions);
  node.addEventListener('focusin',reportActions);
  node.addEventListener('pointerleave',event => {
    const rect = actions.getBoundingClientRect();
    // Entering the native overlay must keep its buttons mounted under the mouse.
    if (event.clientX >= rect.x && event.clientX <= rect.x + 66 && event.clientY >= rect.y && event.clientY <= rect.y + 30) return;
    clearActions();
  });
  function draw() {
    titleElement.textContent = value.title ?? generatedTitle;
    note.innerHTML = renderMarkdown(value.note ?? ''); note.hidden = !value.note || editingField === 'note';
  }
  function format(key) {
    if (!editor || editingField !== 'note' || !markers[key]) return false;
    const wrapped = wrapSelection(editor.value,editor.selectionStart,editor.selectionEnd,markers[key]);
    editor.value = wrapped.value; editor.setSelectionRange(wrapped.start,wrapped.end); draft(); return true;
  }
  function draft() { send({type:'annotation',blockId:id,field:editingField,value:editor.value,phase:'draft'}); }
  function close() {
    detachNative?.(); detachNative = null;
    editor?.closest('.node-edit-box').remove(); titleElement.parentElement.hidden = false;
    editor = null; editingField = null; node.classList.remove('editing');
    const active = window.papericoFinishAnnotation === finish;
    if (active) window.papericoFinishAnnotation = null;
    if (window.papericoFormatNodeNote === format) window.papericoFormatNodeNote = null;
    if (active) send({type:'annotationFocus',note:false,editing:false});
  }
  function finish(commit) {
    if (!editor) return true;
    if (commit && editingField === 'title' && !editor.value.trim()) { if (!window.papericoNativeAnnotations) editor.focus(); return false; }
    if (commit) {
      value = {...value,[editingField]:editor.value.trim()};
      if (value.title === generatedTitle) delete value.title;
      send({type:'annotation',blockId:id,field:editingField,value:editor.value,phase:'commit'});
    } else { send({type:'annotation',blockId:id,phase:'cancel'}); }
    close(); draw(); return true;
  }
  function begin(field) {
    if (!['title','note'].includes(field)) return;
    if (window.papericoFinishAnnotation && window.papericoFinishAnnotation(true) === false) return;
    if (editor) finish(false);
    window.papericoFinishAnnotation = finish;
    editingField = field;
    clearActions();
    const box = document.createElement('div'); box.className = 'node-edit-box';
    editor = document.createElement('textarea'); editor.className = 'node-editor'; editor.rows = field === 'note' ? 3 : 2;
    editor.value = field === 'note' ? value.note ?? '' : value.title ?? generatedTitle;
    editor.placeholder = field === 'note' ? '写下这个节点的笔记…' : '修改逻辑链…';
    editor.setAttribute('aria-label', field === 'note' ? '节点笔记' : '逻辑链内容');
    const fieldSurface = document.createElement('div'); fieldSurface.className = 'node-editor-field';
    fieldSurface.append(editor); box.append(fieldSurface);
    attachCornerResize(fieldSurface);

    const controls = document.createElement('div'); controls.className = 'node-edit-controls';
    for (const [commit,label,icon] of [
      [true,'保存','<path d="M5 12l4 4L19 6"/>'],
      [false,'取消','<path d="M6 6l12 12M18 6L6 18"/>']
    ]) {
      const button = document.createElement('button'); button.type = 'button';
      button.className = 'node-glass-button' + (commit ? ' node-glass-primary' : '');
      button.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${icon}</svg>`;
      const text = document.createElement('span'); text.textContent = label; button.append(text);
      button.setAttribute('aria-label',label);
      button.addEventListener('click', event => { event.stopPropagation(); finish(commit); });
      controls.append(button);
    }
    box.append(controls);
    if (field === 'title') {
      box.classList.add('node-title-edit');
      titleElement.parentElement.after(box); titleElement.parentElement.hidden = true;
    } else {
      node.append(box); note.hidden = true;
    }
    node.classList.add('editing');
    if (window.papericoNativeAnnotations) {
      box.classList.add('node-native-editor');
      fieldSurface.style.height = field === 'note' ? '96px' : '80px';
      const font = getComputedStyle(field === 'note' ? note : titleElement);
      detachNative = attachNativeEditor(fieldSurface, editor, id, field,
        {fontSize:parseFloat(font.fontSize) || 14,fontWeight:parseFloat(font.fontWeight) || 400}, send, draft, finish);
    } else { editor.focus(); }
    send({type:'annotationFocus',note:field === 'note',native:Boolean(window.papericoNativeAnnotations),editing:true}); draft();
    editor.addEventListener('input',draft);
    editor.addEventListener('keydown',event=>{
      if (event.isComposing) return;
      if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); finish(true); }
      else if (event.key === 'Escape') { event.preventDefault(); finish(false); }
      else if (event.metaKey && markers[event.key.toLowerCase()] && format(event.key.toLowerCase())) { event.preventDefault(); }
    });
    window.papericoFormatNodeNote = format;
  }
  draw();
  return {begin,update(next) { value = next || {}; draw(); }};
}

// Native SwiftUI renders the editor. The DOM keeps only its layout slot so
// scrolling, node alignment and reflow remain owned by the document.
function attachNativeEditor(surface, editor, id, field, typography, send, draft, finish) {
  let frame = null, disposed = false;
  function report() {
    frame = null;
    if (disposed) return;
    const rect = surface.getBoundingClientRect();
    send({type:'annotationEditor',blockId:id,field,value:editor.value,active:true,...typography,
          rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});
  }
  function schedule() { if (frame == null) frame = requestAnimationFrame(report); }
  function input(blockId, editingField, value, phase) {
    if (disposed || blockId !== id || editingField !== field) return false;
    editor.value = String(value);
    if (phase === 'commit' || phase === 'cancel') return finish(phase === 'commit');
    draft(); return true;
  }
  function resize(blockId, editingField, width, height) {
    if (disposed || blockId !== id || editingField !== field || !Number.isFinite(width) || !Number.isFinite(height)) return false;
    const size = annotationSize(width,height,0,0,surface.parentElement.clientWidth);
    surface.style.width = `${size.width}px`; surface.style.height = `${size.height}px`;
    schedule(); return true;
  }
  const observer = new ResizeObserver(schedule); observer.observe(document.documentElement); observer.observe(surface);
  window.addEventListener('scroll',schedule,true); window.addEventListener('resize',schedule);
  window.papericoAnnotationInput = input; window.papericoResizeAnnotation = resize;
  schedule();
  return () => {
    disposed = true; observer.disconnect(); if (frame != null) cancelAnimationFrame(frame);
    window.removeEventListener('scroll',schedule,true); window.removeEventListener('resize',schedule);
    if (window.papericoAnnotationInput === input) {
      window.papericoAnnotationInput = null; window.papericoResizeAnnotation = null;
      send({type:'annotationEditor',blockId:id,active:false});
    }
  };
}

// The corner is an invisible input surface, not a resize icon or an extra action.
// Pointer capture keeps resizing stable when the cursor leaves the small corner.
export function annotationSize(width, height, dx, dy, maximumWidth) {
  const maximum = Math.max(0, maximumWidth);
  return {width: Math.min(maximum, Math.max(Math.min(120, maximum), width + dx)),
          height: Math.max(64, height + dy)};
}
function attachCornerResize(surface) {
  const corner = document.createElement('div'); corner.className = 'node-resize-corner';
  corner.setAttribute('aria-hidden','true'); surface.append(corner);
  let start = null;
  corner.addEventListener('pointerdown', event => {
    if (event.button !== 0) return;
    event.preventDefault(); event.stopPropagation();
    const rect = surface.getBoundingClientRect();
    start = {x:event.clientX,y:event.clientY,width:rect.width,height:rect.height};
    corner.setPointerCapture(event.pointerId);
  });
  corner.addEventListener('pointermove', event => {
    if (!start) return;
    event.preventDefault(); event.stopPropagation();
    const size = annotationSize(start.width,start.height,event.clientX-start.x,event.clientY-start.y,surface.parentElement.clientWidth);
    surface.style.width = `${size.width}px`; surface.style.height = `${size.height}px`;
  });
  for (const type of ['pointerup','pointercancel','lostpointercapture']) {
    corner.addEventListener(type, event => {
      if (!start) return;
      event.stopPropagation(); start = null;
      if (corner.hasPointerCapture(event.pointerId)) corner.releasePointerCapture(event.pointerId);
    });
  }
}
