import { useEffect, useRef, useState } from 'react';
import { Check, Copy, FileText, Image, Loader2, BotMessageSquare, PenLine, Plus, Send, Astroid, Tag, X } from 'lucide-react';
import { useParams } from 'react-router-dom';
import ReactMarkdown from 'react-markdown';
import remarkMath from 'remark-math';
import rehypeKatex from 'rehype-katex';
import { api } from '../../api/client';
import { useChatStore, useReaderStore, useSettingsStore } from '../../stores';
import type { Note } from '../../api/types';

export default function ChatPanel() {
  const { paperId } = useParams<{ paperId: string }>();
  const { currentSession, streaming, streamContent, sendMessage, newSession, sessions, loadSession } = useChatStore();
  const { attachedContext, removeAttachedContext, clearAttachedContext } = useReaderStore();
  const settings = useSettingsStore((state) => state.settings);
  const [input, setInput] = useState('');
  const [noteMode, setNoteMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [notes, setNotes] = useState<Note[]>([]);
  const [busyNote, setBusyNote] = useState(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const endRef = useRef<HTMLDivElement>(null);
  const messages = currentSession?.messages || [];
  const prompts = settings?.chat_defaults?.preset_prompts || [];

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages, streamContent]);
  useEffect(() => { if (paperId) api.notes.list(paperId).then(setNotes).catch(() => {}); }, [paperId]);

  const send = async (value?: string) => {
    const content = (value ?? input).trim();
    if (!paperId || !content || streaming) return;
    setInput('');
    await sendMessage(paperId, content, attachedContext.length ? [...attachedContext] : undefined);
    clearAttachedContext();
  };

  const synthesizeNote = async () => {
    if (!paperId || !selectedIds.length) return;
    setBusyNote(true);
    try {
      const note = await api.notes.synthesize(paperId, { message_ids: selectedIds });
      setNotes((items) => [note, ...items]);
      setSelectedIds([]);
      setNoteMode(false);
    } finally { setBusyNote(false); }
  };

  return (
    <div className="chat-panel-inner">
      <div className="chat-session-bar">
        <button onClick={newSession}><Plus size={13} />新对话</button>
        {sessions.length > 0 && <select value={currentSession?.id || ''} onChange={(event) => event.target.value && paperId && loadSession(paperId, event.target.value)}><option value="">历史对话</option>{sessions.map((session) => <option key={session.id} value={session.id}>{session.title || '未命名对话'}</option>)}</select>}
        <button className={noteMode ? 'active' : ''} onClick={() => setNoteMode((value) => !value)} title="选择回答导出笔记"><PenLine size={14} /></button>
      </div>

      <div className="chat-messages">
        {!messages.length && !streaming && <div className="chat-empty"><span className="chat-empty-mark"><Astroid size={16} /><BotMessageSquare size={24} /></span><strong>向论文提问</strong><span>支持追问、选中文本，回答可回溯原文。</span></div>}
        {messages.map((message) => (
          <div key={message.id} className={`chat-message ${message.role}`}>
            {noteMode && <label className="note-select"><input type="checkbox" checked={selectedIds.includes(message.id)} onChange={(event) => setSelectedIds((ids) => event.target.checked ? [...ids, message.id] : ids.filter((id) => id !== message.id))} />选入笔记</label>}
            <div className="chat-bubble">
              {message.attached_context?.length ? <div className="message-context">{message.attached_context.map((context, index) => <span key={index}>{context.snippet?.slice(0, 36) || context.type}</span>)}</div> : null}
              {message.role === 'assistant' ? <div className="chat-markdown"><ReactMarkdown remarkPlugins={[remarkMath]} rehypePlugins={[rehypeKatex]}>{message.content}</ReactMarkdown></div> : <p>{message.content}</p>}
              {message.cited_block_ids?.length ? <div className="citation-row">{message.cited_block_ids.map((id) => <button key={id} onClick={() => {
                const reader = useReaderStore.getState();
                if (reader.viewMode === 'pdf') {
                  reader.requestPdfFocus(id);
                  return;
                }
                document.getElementById(`block-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'center' });
              }}>证据 {id.split('-').pop()}</button>)}</div> : null}
            </div>
            {message.role === 'assistant' && <button className="copy-message" onClick={async () => { await navigator.clipboard.writeText(message.content); setCopiedId(message.id); window.setTimeout(() => setCopiedId(null), 1600); }}>{copiedId === message.id ? <Check size={10} /> : <Copy size={10} />}</button>}
          </div>
        ))}
        {streaming && <div className="chat-message assistant"><div className="chat-bubble"><div className="chat-markdown"><ReactMarkdown remarkPlugins={[remarkMath]} rehypePlugins={[rehypeKatex]}>{streamContent || '正在思考…'}</ReactMarkdown></div><Loader2 size={11} className="animate-spin" /></div></div>}
        <div ref={endRef} />
      </div>

      {attachedContext.length > 0 && <div className="attached-row">{attachedContext.map((context, index) => <span key={index}>{context.type === 'text_selection' ? <FileText size={10} /> : context.type === 'figure' ? <Image size={10} /> : <Tag size={10} />}{context.snippet?.slice(0, 28) || context.type}<button onClick={() => removeAttachedContext(index)}><X size={9} /></button></span>)}</div>}
      {prompts.length > 0 && <div className="prompt-row">{prompts.slice(0, 4).map((prompt) => <button key={prompt.label} onClick={() => setInput(prompt.template)}>{prompt.label}</button>)}</div>}

      {noteMode && <div className="note-toolbar"><span>已选 {selectedIds.length} 条</span><button disabled={!selectedIds.length || busyNote} onClick={synthesizeNote}>{busyNote ? <Loader2 size={10} className="animate-spin" /> : '生成笔记'}</button>{notes[0] && <button onClick={() => downloadNote(notes[0])}>下载最近笔记</button>}</div>}

      <div className="chat-composer">
        <textarea rows={2} value={input} onChange={(event) => setInput(event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); send(); } }} placeholder="针对这篇论文提问…" disabled={streaming} />
        <button onClick={() => send()} disabled={!input.trim() || streaming} aria-label="发送"><Send size={16} /></button>
      </div>
    </div>
  );
}

function downloadNote(note: Note) {
  const url = URL.createObjectURL(new Blob([note.markdown_content], { type: 'text/markdown' }));
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = `${note.title || 'paper-note'}.md`;
  anchor.click();
  URL.revokeObjectURL(url);
}
