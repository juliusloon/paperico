import { create } from 'zustand';
import type {
  ProjectGroup, PaperListItem, PaperDetail,
  ChatSession, ChatMessage, AttachedContext, AppSettings
} from '../api/types';
import { api } from '../api/client';

// ── App Store (global UI state) ──
interface AppState {
  theme: 'light' | 'dark' | 'system';
  accentColor: string;
  setTheme: (t: 'light' | 'dark' | 'system') => void;
  setAccentColor: (c: string) => void;
}

export const useAppStore = create<AppState>((set) => ({
  theme: 'system',
  accentColor: '#2F6FED',
  setTheme: (theme) => {
    set({ theme });
    applyTheme(theme);
  },
  setAccentColor: (accentColor) => {
    set({ accentColor });
    document.documentElement.style.setProperty('--accent-user', accentColor);
  },
}));

function applyTheme(theme: string) {
  const isDark = theme === 'dark' || (theme === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.classList.toggle('dark', isDark);
}

function applyAppearance(appearance: AppSettings['appearance']) {
  useAppStore.setState({
    theme: appearance.theme_mode as AppState['theme'],
    accentColor: appearance.accent_color,
  });
  document.documentElement.style.setProperty('--accent-user', appearance.accent_color);
  applyTheme(appearance.theme_mode);
}

// ── Projects Store ──
interface ProjectsState {
  projects: ProjectGroup[];
  loading: boolean;
  fetch: () => Promise<void>;
  create: (name: string, description?: string) => Promise<ProjectGroup>;
  renameProject: (id: string, name: string) => Promise<void>;
  deleteProject: (id: string) => Promise<void>;
}

export const useProjectsStore = create<ProjectsState>((set) => ({
  projects: [],
  loading: false,
  fetch: async () => {
    set({ loading: true });
    try {
      const projects = await api.projects.list();
      set({ projects, loading: false });
    } catch {
      set({ loading: false });
    }
  },
  create: async (name, description) => {
    const p = await api.projects.create({ name, description });
    set((s) => ({ projects: [...s.projects, p] }));
    return p;
  },
  renameProject: async (id, name) => {
    const existing = (useProjectsStore.getState()).projects.find((p) => p.id === id);
    if (!existing) return;
    const updated = await api.projects.update(id, { name, description: existing.description, color_tag: existing.color_tag });
    set((s) => ({ projects: s.projects.map((p) => p.id === id ? updated : p) }));
  },
  deleteProject: async (id) => {
    await api.projects.delete(id);
    set((s) => ({ projects: s.projects.filter((p) => p.id !== id) }));
  },
}));

// ── Papers Store ──
interface PapersState {
  papers: PaperListItem[];
  loading: boolean;
  error: string;
  filter: { project_id?: string; q?: string };
  fetch: (filter?: { project_id?: string; q?: string }) => Promise<void>;
  upload: (file: File, projectId?: string) => Promise<PaperListItem>;
  movePapers: (paperIds: string[], projectId: string | null) => Promise<void>;
  renamePaper: (id: string, title: string) => Promise<void>;
  deletePaper: (id: string) => Promise<void>;
  setFilter: (f: { project_id?: string; q?: string }) => void;
}

export const usePapersStore = create<PapersState>((set) => ({
  papers: [],
  loading: false,
  error: '',
  filter: {},
  fetch: async (filter) => {
    set({ loading: true, error: '' });
    const f = filter || {};
    try {
      const papers = await api.papers.list(f);
      set({ papers, loading: false, filter: f });
    } catch (error) {
      const message = error instanceof DOMException && error.name === 'TimeoutError'
        ? '论文库响应超时，请重试。后台论文处理不会因此中断。'
        : error instanceof Error ? error.message : '论文库加载失败';
      set({ loading: false, error: message, filter: f });
    }
  },
  upload: async (file, projectId) => {
    const paper = await api.papers.create(file, projectId);
    set((s) => ({ papers: [paper, ...s.papers] }));
    return paper;
  },
  movePapers: async (paperIds, projectId) => {
    if (!paperIds.length) return;
    await api.papers.move(paperIds, projectId);
    const selected = new Set(paperIds);
    set((s) => ({
      papers: s.filter.project_id && s.filter.project_id !== projectId
        ? s.papers.filter((paper) => !selected.has(paper.id))
        : s.papers.map((paper) => selected.has(paper.id) ? { ...paper, project_id: projectId } : paper),
    }));
  },
  renamePaper: async (id, title) => {
    const updated = await api.papers.rename(id, title);
    set((s) => ({ papers: s.papers.map((p) => p.id === id ? updated : p) }));
  },
  deletePaper: async (id) => {
    await api.papers.delete(id);
    set((s) => ({ papers: s.papers.filter((p) => p.id !== id) }));
  },
  setFilter: (f) => set({ filter: f }),
}));

// ── Reader Store (single paper reading session) ──
interface ReaderState {
  paper: PaperDetail | null;
  error: string;
  loading: boolean;
  // UI state
  showTranslation: boolean;
  bilingualMode: 'original' | 'translation' | 'bilingual';
  fontSize: number;
  leftPanelCollapsed: boolean;
  leftPanelDensity: 'compact' | 'detailed';
  activeBlockId: string | null;
  highlightedEntities: string[];
  selectedText: string;
  // Mirrored from ReadingArea so components outside it (chat cited chips,
  // mobile outline) know whether the PDF canvas is the active surface.
  viewMode: 'text' | 'pdf';
  // T2.3: a pending "locate this block on the PDF canvas" request. The token
  // increments so re-clicking the same block re-triggers the jump.
  pendingPdfFocus: { blockId: string; token: number } | null;
  // Attached context for chat
  attachedContext: AttachedContext[];

  fetchPaper: (id: string) => Promise<void>;
  refreshPaper: (id: string) => Promise<void>;
  setBilingualMode: (m: 'original' | 'translation' | 'bilingual') => void;
  setFontSize: (s: number) => void;
  toggleLeftPanel: () => void;
  setLeftPanelDensity: (d: 'compact' | 'detailed') => void;
  setActiveBlock: (id: string | null) => void;
  highlightEntities: (ids: string[]) => void;
  setSelectedText: (t: string) => void;
  requestPdfFocus: (blockId: string) => void;
  addAttachedContext: (ctx: AttachedContext) => void;
  removeAttachedContext: (idx: number) => void;
  clearAttachedContext: () => void;
}

let readerRequestVersion = 0;

export const useReaderStore = create<ReaderState>((set, get) => ({
  paper: null,
  error: '',
  loading: false,
  showTranslation: true,
  bilingualMode: 'bilingual',
  fontSize: 18,
  leftPanelCollapsed: false,
  leftPanelDensity: 'detailed',
  activeBlockId: null,
  highlightedEntities: [],
  selectedText: '',
  viewMode: 'text',
  pendingPdfFocus: null,
  attachedContext: [],

  fetchPaper: async (id) => {
    const version = ++readerRequestVersion;
    set({ loading: true, paper: null, error: '', attachedContext: [], activeBlockId: null, pendingPdfFocus: null });
    try {
      const paper = await api.papers.get(id);
      if (version === readerRequestVersion) set({ paper, loading: false });
    } catch (error) {
      if (version === readerRequestVersion) set({ loading: false, error: error instanceof Error ? error.message : '论文加载失败，请重试。' });
    }
  },
  refreshPaper: async (id) => {
    const version = readerRequestVersion;
    const paper = await api.papers.get(id);
    if (version === readerRequestVersion && get().paper?.paper.id === id) set({ paper });
  },
  setBilingualMode: (m) => set({ bilingualMode: m, showTranslation: m !== 'original' }),
  setFontSize: (s) => set({ fontSize: s }),
  toggleLeftPanel: () => set((s) => ({ leftPanelCollapsed: !s.leftPanelCollapsed })),
  setLeftPanelDensity: (d) => set({ leftPanelDensity: d }),
  setActiveBlock: (id) => set({ activeBlockId: id }),
  highlightEntities: (ids) => set({ highlightedEntities: ids }),
  setSelectedText: (t) => set({ selectedText: t }),
  requestPdfFocus: (blockId) => set((s) => ({
    pendingPdfFocus: { blockId, token: (s.pendingPdfFocus?.token || 0) + 1 },
  })),
  addAttachedContext: (ctx) => set((s) => {
    const duplicate = s.attachedContext.some((item) => (
      item.type === ctx.type
      && item.ref_entity_id === ctx.ref_entity_id
      && item.ref_block_id === ctx.ref_block_id
      && item.snippet === ctx.snippet
    ));
    return duplicate ? s : { attachedContext: [...s.attachedContext, ctx] };
  }),
  removeAttachedContext: (idx) => set((s) => ({
    attachedContext: s.attachedContext.filter((_, i) => i !== idx),
  })),
  clearAttachedContext: () => set({ attachedContext: [] }),
}));

// ── Chat Store ──
interface ChatState {
  sessions: ChatSession[];
  currentSession: ChatSession | null;
  streaming: boolean;
  streamContent: string;

  fetchSessions: (paperId: string) => Promise<void>;
  loadSession: (paperId: string, sessionId: string) => Promise<void>;
  sendMessage: (paperId: string, content: string, attachedContext?: AttachedContext[]) => Promise<void>;
  newSession: () => void;
}

export const useChatStore = create<ChatState>((set, get) => ({
  sessions: [],
  currentSession: null,
  streaming: false,
  streamContent: '',

  fetchSessions: async (paperId) => {
    const sessions = await api.chat.listSessions(paperId);
    set({ sessions });
  },
  loadSession: async (paperId, sessionId) => {
    const session = await api.chat.getSession(paperId, sessionId);
    set({ currentSession: session });
  },
  sendMessage: async (paperId, content, attachedContext) => {
    const { currentSession } = get();
    set({ streaming: true, streamContent: '' });

    // Add user message locally immediately
    const userMsg: ChatMessage = {
      id: 'temp-' + Date.now(),
      session_id: currentSession?.id || '',
      role: 'user',
      content,
      attached_context: attachedContext || null,
      cited_block_ids: null,
      created_at: new Date().toISOString(),
    };

    if (currentSession) {
      set({ currentSession: { ...currentSession, messages: [...currentSession.messages, userMsg] } });
    }

    let fullContent = '';
    let sessionId = currentSession?.id;
    let assistantMsgId = '';
    let citedBlockIds: string[] = [];

    try {
      for await (const event of api.chat.send(paperId, {
        content,
        session_id: sessionId,
        attached_context: attachedContext,
      })) {
        if (event.content) {
          fullContent += event.content;
          set({ streamContent: fullContent });
        }
        if (event.session_id) {
          sessionId = event.session_id;
        }
        if (event.message_id) {
          assistantMsgId = event.message_id;
          citedBlockIds = event.cited_block_ids || [];
        }
      }
    } catch (e) {
      fullContent += `\n\n[错误: ${e instanceof Error ? e.message : '未知错误'}]`;
      set({ streamContent: fullContent });
    }

    // Finalize: add assistant message
    const assistantMsg: ChatMessage = {
      id: assistantMsgId || 'msg-' + Date.now(),
      session_id: sessionId || '',
      role: 'assistant',
      content: fullContent,
      attached_context: null,
      cited_block_ids: citedBlockIds,
      created_at: new Date().toISOString(),
    };

    const updatedSession: ChatSession = {
      id: sessionId || '',
      paper_id: paperId,
      title: content.slice(0, 50),
      messages: [...(currentSession?.messages || []), userMsg, assistantMsg],
      created_at: currentSession?.created_at || new Date().toISOString(),
    };

    set({
      currentSession: updatedSession,
      streaming: false,
      streamContent: '',
    });

    // Refresh sessions list
    get().fetchSessions(paperId);
  },
  newSession: () => set({ currentSession: null, streamContent: '' }),
}));

// ── Settings Store ──
interface SettingsState {
  settings: AppSettings | null;
  loading: boolean;
  fetch: () => Promise<void>;
  update: (data: Partial<AppSettings>) => Promise<void>;
}

export const useSettingsStore = create<SettingsState>((set) => ({
  settings: null,
  loading: false,
  fetch: async () => {
    set({ loading: true });
    const settings = await api.settings.get();
    set({ settings, loading: false });
    if (settings.appearance) applyAppearance(settings.appearance);
  },
  update: async (data) => {
    const settings = await api.settings.update(data);
    set({ settings });
    if (settings.appearance) applyAppearance(settings.appearance);
  },
}));
