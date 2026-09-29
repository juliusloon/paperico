import type {
  ProjectGroup, PaperListItem, PaperDetail, ChatSession,
  Note, AppSettings, MethodIndexItem
} from './types';

const BASE = '/api';
const LIST_TIMEOUT_MS = 10000;

async function fetchJSON<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${url}`, {
    headers: { 'Content-Type': 'application/json', ...init?.headers },
    ...init,
  });
  if (!res.ok) {
    const text = await res.text();
    let message = text;
    try {
      const payload = JSON.parse(text) as { detail?: unknown; message?: unknown };
      const detail = payload.detail ?? payload.message;
      if (typeof detail === 'string' && detail.trim()) message = detail;
    } catch {
      // Keep the raw response when the server did not return JSON.
    }
    throw new Error(`${res.status}: ${message}`);
  }
  return res.json();
}

// ── Projects ──
export const api = {
  projects: {
    list: () => fetchJSON<ProjectGroup[]>('/projects', { signal: AbortSignal.timeout(LIST_TIMEOUT_MS) }),
    create: (data: { name: string; description?: string; color_tag?: string }) =>
      fetchJSON<ProjectGroup>('/projects', { method: 'POST', body: JSON.stringify(data) }),
    update: (id: string, data: { name: string; description?: string; color_tag?: string }) =>
      fetchJSON<ProjectGroup>(`/projects/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
    delete: (id: string) =>
      fetchJSON<{ ok: boolean }>(`/projects/${id}`, { method: 'DELETE' }),
  },

  // ── Papers ──
  papers: {
    list: (params?: { project_id?: string; status?: string; q?: string }) => {
      const sp = new URLSearchParams();
      if (params?.project_id) sp.set('project_id', params.project_id);
      if (params?.status) sp.set('status', params.status);
      if (params?.q) sp.set('q', params.q);
      const qs = sp.toString();
      return fetchJSON<PaperListItem[]>(`/papers${qs ? '?' + qs : ''}`, { signal: AbortSignal.timeout(LIST_TIMEOUT_MS) });
    },
    create: async (file?: File, projectId?: string, url?: string) => {
      const form = new FormData();
      if (file) form.append('file', file);
      if (projectId) form.append('project_id', projectId);
      if (url) form.append('source_url', url);
      const res = await fetch(`${BASE}/papers`, { method: 'POST', body: form });
      if (!res.ok) throw new Error(`${res.status}: ${await res.text()}`);
      return res.json() as Promise<PaperListItem>;
    },
    get: (id: string) => fetchJSON<PaperDetail>(`/papers/${id}`),
    status: (id: string) => fetchJSON<{ id: string; status: string; error_message: string; error_code?: string }>(`/papers/${id}/status`),
    reparse: (id: string) => fetchJSON<{ id: string; status: string; error_message: string }>(`/papers/${id}/reparse`, { method: 'POST' }),
    retranslate: (id: string) => fetchJSON<{ id: string; status: string; error_message: string }>(`/papers/${id}/retranslate`, { method: 'POST' }),
    move: (paperIds: string[], projectId: string | null) =>
      fetchJSON<{ ok: boolean; moved: number; project_id: string | null }>('/papers/project', {
        method: 'PATCH',
        body: JSON.stringify({ paper_ids: paperIds, project_id: projectId }),
      }),
    rename: (id: string, title: string) =>
      fetchJSON<PaperListItem>(`/papers/${id}/title`, { method: 'PATCH', body: JSON.stringify({ title }) }),
    delete: (id: string) => fetchJSON<{ ok: boolean }>(`/papers/${id}`, { method: 'DELETE' }),
  },

  // ── Chat ──
  chat: {
    send: async function* (paperId: string, data: { content: string; session_id?: string; attached_context?: any[] }) {
      const res = await fetch(`${BASE}/papers/${paperId}/chat`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data),
      });
      if (!res.ok || !res.body) throw new Error(`Chat failed: ${res.status}`);

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop() || '';

        for (const line of lines) {
          if (line.startsWith('data: ')) {
            try {
              const parsed = JSON.parse(line.slice(6));
              if (parsed.error) throw new Error(parsed.error);
              yield parsed;
            } catch { /* skip malformed */ }
          }
        }
      }
    },
    listSessions: (paperId: string) =>
      fetchJSON<ChatSession[]>(`/papers/${paperId}/chat`),
    getSession: (paperId: string, sessionId: string) =>
      fetchJSON<ChatSession>(`/papers/${paperId}/chat/${sessionId}`),
  },

  // ── Notes ──
  notes: {
    list: (paperId: string) => fetchJSON<Note[]>(`/papers/${paperId}/notes`),
    synthesize: (paperId: string, data: { title?: string; message_ids: string[] }) =>
      fetchJSON<Note>(`/papers/${paperId}/notes/synthesize`, { method: 'POST', body: JSON.stringify(data) }),
  },

  // ── Settings ──
  settings: {
    get: () => fetchJSON<AppSettings>('/settings'),
    update: (data: Partial<AppSettings>) =>
      fetchJSON<AppSettings>('/settings', { method: 'PUT', body: JSON.stringify(data) }),
    testLLM: (base_url: string, api_key: string, model: string, profile_id = '') =>
      fetchJSON<{ success: boolean; message: string }>('/settings/test-llm', {
        method: 'POST', body: JSON.stringify({ base_url, api_key, model, profile_id }),
      }),
    testMinerU: (opts: { mode: string; base_url: string; local_url: string; api_key: string }) =>
      fetchJSON<{ success: boolean; message: string }>('/settings/test-mineru', {
        method: 'POST', body: JSON.stringify(opts),
      }),
  },

  // ── Library ──
  library: {
    methods: (params?: { project_id?: string; category?: string; q?: string }) => {
      const sp = new URLSearchParams();
      if (params?.project_id) sp.set('project_id', params.project_id);
      if (params?.category) sp.set('category', params.category);
      if (params?.q) sp.set('q', params.q);
      const qs = sp.toString();
      return fetchJSON<MethodIndexItem[]>(`/library/methods${qs ? '?' + qs : ''}`);
    },
  },
};
