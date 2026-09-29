import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import {
  Upload, FolderPlus, Trash2, FileText, Search, X, Loader2, ArrowRight, ShieldAlert,
  Check, PanelLeft, PanelLeftClose, CheckSquare2, Square, GripVertical, FolderInput,
  ListFilter, RefreshCw, MousePointer2, Pencil,
} from 'lucide-react';
import { useProjectsStore, usePapersStore, useSettingsStore } from '../../stores';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import type { PaperListItem } from '../../api/types';

const STATUS_LABELS: Record<string, string> = {
  uploaded: '待解析',
  parsing: '解析中',
  parsed: '已解析',
  normalizing: '清洗中',
  analyzing: '分析中',
  reducing: '归纳中',
  ready: '已就绪',
  error: '出错',
};

const STATUS_COLORS: Record<string, string> = {
  ready: '#16a34a',
  error: '#dc2626',
  parsing: '#f59e0b',
  analyzing: '#f59e0b',
  reducing: '#f59e0b',
  normalizing: '#f59e0b',
  default: '#9a9a9a',
};

export default function LibraryPage() {
  const navigate = useNavigate();
  const { projects, fetch: fetchProjects, create: createProject, renameProject, deleteProject } = useProjectsStore();
  const { papers, loading, error, fetch: fetchPapers, upload, movePapers, renamePaper, deletePaper, filter, setFilter } = usePapersStore();
  const settings = useSettingsStore((state) => state.settings);
  const [showNewProject, setShowNewProject] = useState(false);
  const [projectSidebarCollapsed, setProjectSidebarCollapsed] = useState(false);
  const isMobile = useMediaQuery('(max-width: 760px)');
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false);
  const sidebarCollapsed = projectSidebarCollapsed && !isMobile;
  const [newProjectName, setNewProjectName] = useState('');
  const [searchQuery, setSearchQuery] = useState('');
  const [showUpload, setShowUpload] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState('');
  const [selectionMode, setSelectionMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [statusFilter, setStatusFilter] = useState('all');
  const [sortMode, setSortMode] = useState('recent');
  const [targetProjectId, setTargetProjectId] = useState('');
  const [moving, setMoving] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [actionError, setActionError] = useState('');
  const [draggingIds, setDraggingIds] = useState<string[]>([]);
  const [dropProjectId, setDropProjectId] = useState<string | null>(null);
  const [renamingProjectId, setRenamingProjectId] = useState<string | null>(null);
  const [renamingProjectName, setRenamingProjectName] = useState('');
  const [renamingPaperId, setRenamingPaperId] = useState<string | null>(null);
  const [renamingPaperTitle, setRenamingPaperTitle] = useState('');
  const fileInput = useRef<HTMLInputElement>(null);

  const visiblePapers = useMemo(() => {
    const next = statusFilter === 'all' ? [...papers] : papers.filter((paper) => paper.status === statusFilter);
    next.sort((a, b) => {
      if (sortMode === 'title') return (a.title || a.original_file_name).localeCompare(b.title || b.original_file_name);
      if (sortMode === 'year') return (b.year || 0) - (a.year || 0);
      if (sortMode === 'status') return (STATUS_LABELS[a.status] || a.status).localeCompare(STATUS_LABELS[b.status] || b.status);
      return b.created_at.localeCompare(a.created_at);
    });
    return next;
  }, [papers, sortMode, statusFilter]);

  useEffect(() => {
    fetchProjects();
    fetchPapers();
  }, [fetchProjects, fetchPapers]);

  useEffect(() => {
    const hasActive = papers.some((paper) => !['ready', 'error'].includes(paper.status));
    if (!hasActive) return;
    const timer = window.setInterval(() => fetchPapers(filter), 4000);
    return () => window.clearInterval(timer);
  }, [papers, filter, fetchPapers]);

  const pipelineReady = Boolean(settings?.model_profiles[0]?.api_key_configured && settings?.mineru.api_key_configured);

  const handleUpload = async (files: FileList | null) => {
    if (!files?.length) return;
    if (!pipelineReady) {
      setUploadError('上传前需要先配置并测试 AI 模型 API Key 与 MinerU Token。');
      return;
    }
    setUploading(true);
    setUploadError('');
    let succeeded = false;
    try {
      for (let i = 0; i < files.length; i++) {
        await upload(files[i], filter.project_id);
      }
      fetchPapers(filter);
      succeeded = true;
    } catch (error) {
      setUploadError(error instanceof Error ? error.message : '上传失败');
    } finally {
      setUploading(false);
      if (succeeded) setShowUpload(false);
    }
  };

  const handleCreateProject = async () => {
    if (!newProjectName.trim()) return;
    await createProject(newProjectName.trim());
    setNewProjectName('');
    setShowNewProject(false);
  };

  const handleStartRenameProject = (id: string, currentName: string) => {
    setRenamingProjectId(id);
    setRenamingProjectName(currentName);
  };

  const handleConfirmRenameProject = async () => {
    if (!renamingProjectId || !renamingProjectName.trim()) return;
    await renameProject(renamingProjectId, renamingProjectName.trim());
    setRenamingProjectId(null);
    setRenamingProjectName('');
  };

  const handleCancelRenameProject = () => {
    setRenamingProjectId(null);
    setRenamingProjectName('');
  };

  const handleDeleteProject = async (id: string, name: string) => {
    if (!confirm(`确定删除项目「${name}」？项目内的论文不会被删除，只会移出该分组。`)) return;
    await deleteProject(id);
    if (filter.project_id === id) {
      const f = { ...filter, project_id: undefined };
      setFilter(f);
      fetchPapers(f);
    }
  };

  const handleStartRenamePaper = (id: string, currentTitle: string) => {
    setRenamingPaperId(id);
    setRenamingPaperTitle(currentTitle);
  };

  const handleConfirmRenamePaper = async () => {
    if (!renamingPaperId || !renamingPaperTitle.trim()) return;
    await renamePaper(renamingPaperId, renamingPaperTitle.trim());
    setRenamingPaperId(null);
    setRenamingPaperTitle('');
  };

  const handleCancelRenamePaper = () => {
    setRenamingPaperId(null);
    setRenamingPaperTitle('');
  };

  const toggleProjectSidebar = () => {
    setProjectSidebarCollapsed((collapsed) => {
      if (!collapsed) setShowNewProject(false);
      return !collapsed;
    });
  };

  const handleFilterByProject = (projectId?: string) => {
    const f = { ...filter, project_id: projectId };
    setFilter(f);
    fetchPapers(f);
    setMobileSidebarOpen(false);
  };

  const handleSearch = () => {
    const f = { ...filter, q: searchQuery || undefined };
    setFilter(f);
    fetchPapers(f);
  };

  const handleDelete = async (id: string, e: React.MouseEvent) => {
    e.stopPropagation();
    if (!confirm('确定删除这篇论文？')) return;
    await deletePaper(id);
    setSelectedIds((selected) => {
      const next = new Set(selected);
      next.delete(id);
      return next;
    });
    fetchProjects();
  };

  const toggleSelection = (id: string) => {
    setSelectedIds((selected) => {
      const next = new Set(selected);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const toggleSelectAll = () => {
    const visibleIds = visiblePapers.map((paper) => paper.id);
    const allSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedIds.has(id));
    setSelectedIds((selected) => {
      const next = new Set(selected);
      visibleIds.forEach((id) => allSelected ? next.delete(id) : next.add(id));
      return next;
    });
  };

  const clearSelection = () => {
    setSelectedIds(new Set());
    setSelectionMode(false);
    setTargetProjectId('');
  };

  const handleMove = async (ids: string[], projectId: string | null) => {
    if (!ids.length) return;
    setMoving(true);
    setActionError('');
    try {
      await movePapers(ids, projectId);
      await fetchProjects();
      clearSelection();
    } catch (error) {
      setActionError(error instanceof Error ? error.message : '移动论文失败，请重试。');
    } finally {
      setMoving(false);
      setDraggingIds([]);
      setDropProjectId(null);
    }
  };

  const handleBatchDelete = async () => {
    const ids = [...selectedIds];
    if (!ids.length || !confirm(`确定删除选中的 ${ids.length} 篇论文？此操作会同时删除对应的解析数据。`)) return;
    setDeleting(true);
    setActionError('');
    try {
      await Promise.all(ids.map((id) => deletePaper(id)));
      await fetchProjects();
      clearSelection();
    } catch (error) {
      setActionError(error instanceof Error ? error.message : '批量删除失败，请重试。');
    } finally {
      setDeleting(false);
    }
  };

  const handleDragStart = (paper: PaperListItem, event: React.DragEvent) => {
    const ids = selectedIds.has(paper.id) ? [...selectedIds] : [paper.id];
    if (!selectedIds.has(paper.id)) setSelectedIds(new Set([paper.id]));
    setSelectionMode(true);
    setDraggingIds(ids);
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('application/x-paperico-paper-ids', JSON.stringify(ids));
    event.dataTransfer.setData('text/plain', ids.join(','));
  };

  const handleDropOnProject = (projectId: string, event: React.DragEvent) => {
    event.preventDefault();
    let ids = draggingIds;
    try {
      const parsed = JSON.parse(event.dataTransfer.getData('application/x-paperico-paper-ids'));
      if (Array.isArray(parsed)) ids = parsed.filter((id): id is string => typeof id === 'string');
    } catch { /* use in-memory drag selection */ }
    void handleMove(ids, projectId);
  };

  return (
    <div className="h-full flex library-page">
      {/* Sidebar: Projects */}
      <aside
        className={`w-60 shrink-0 border-r flex flex-col overflow-hidden library-sidebar${sidebarCollapsed ? ' collapsed' : ''}${mobileSidebarOpen ? ' mobile-open' : ''}`}
        style={{ background: 'var(--gray-50)', borderColor: 'var(--gray-200)' }}
      >
        <div className="p-3 border-b flex items-center justify-between library-sidebar-header" style={{ borderColor: 'var(--gray-200)' }}>
          <span className="text-xs font-medium" style={{ color: 'var(--gray-600)' }}>项目分组</span>
          <div className="library-sidebar-actions">
            <button className="library-sidebar-new" onClick={() => setShowNewProject(true)} title="新建项目"><FolderPlus size={14} /></button>
            <button
              onClick={isMobile ? () => setMobileSidebarOpen(false) : toggleProjectSidebar}
              title={isMobile ? '关闭项目分组' : projectSidebarCollapsed ? '展开项目分组' : '收起项目分组'}
            >
              {isMobile ? <X size={14} /> : projectSidebarCollapsed ? <PanelLeft size={14} /> : <PanelLeftClose size={14} />}
            </button>
          </div>
        </div>

        {!sidebarCollapsed && showNewProject && (
          <div className="library-new-project">
            <label>
              <span><FolderPlus size={13} />新建项目</span>
            <input
              autoFocus
              value={newProjectName}
              onChange={(e) => setNewProjectName(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && handleCreateProject()}
              placeholder="项目名称"
                aria-label="项目名称"
            />
            </label>
            <div className="library-new-project-actions">
              <button className="confirm" onClick={handleCreateProject} disabled={!newProjectName.trim()}><Check size={13} />创建</button>
              <button onClick={() => { setShowNewProject(false); setNewProjectName(''); }}>取消</button>
            </div>
          </div>
        )}

        {!sidebarCollapsed && <div className="flex-1 overflow-y-auto library-project-list">
          {draggingIds.length > 0 && (
            <div className="library-drop-hint"><FolderInput size={13} /><span>拖到项目名称完成分组</span></div>
          )}
          <button
            onClick={() => handleFilterByProject(undefined)}
            className="w-full text-left px-3 py-2 text-xs transition-fast flex items-center justify-between"
            style={{
              color: !filter.project_id ? 'var(--accent)' : 'var(--gray-700)',
              background: !filter.project_id ? 'var(--accent-soft)' : 'transparent',
            }}
          >
            <span>全部论文</span>
            <span className="text-[10px] opacity-60">{filter.project_id ? projects.reduce((sum, p) => sum + p.paper_count, 0) : papers.length}</span>
          </button>
          {projects.map((p) => (
            renamingProjectId === p.id ? (
              <div key={p.id} className="library-project-rename">
                <input
                  autoFocus
                  value={renamingProjectName}
                  onChange={(e) => setRenamingProjectName(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') handleConfirmRenameProject();
                    if (e.key === 'Escape') handleCancelRenameProject();
                  }}
                  className="w-full px-2 py-1 text-xs rounded border outline-none"
                  style={{ background: 'var(--gray-0)', borderColor: 'var(--accent)' }}
                />
                <div className="library-project-rename-actions">
                  <button className="confirm" onClick={handleConfirmRenameProject} disabled={!renamingProjectName.trim()}><Check size={12} /></button>
                  <button onClick={handleCancelRenameProject}><X size={12} /></button>
                </div>
              </div>
            ) : (
              <button
                key={p.id}
                onClick={() => handleFilterByProject(p.id)}
                onDragOver={(event) => { event.preventDefault(); event.dataTransfer.dropEffect = 'move'; setDropProjectId(p.id); }}
                onDragLeave={() => setDropProjectId((current) => current === p.id ? null : current)}
                onDrop={(event) => handleDropOnProject(p.id, event)}
                className={`w-full text-left px-3 py-2 text-xs transition-fast flex items-center justify-between library-project-target${dropProjectId === p.id ? ' is-drop-target' : ''}`}
                style={{
                  color: filter.project_id === p.id ? 'var(--accent)' : 'var(--gray-700)',
                  background: filter.project_id === p.id ? 'var(--accent-soft)' : 'transparent',
                }}
              >
                <span className="truncate"><span className="library-project-dot" style={{ background: p.color_tag || 'var(--accent)' }} />{p.name}</span>
                <span className="library-project-actions">
                  <span className="text-[10px] opacity-60 mr-1">{p.paper_count}</span>
                  <button
                    className="library-project-action-btn"
                    onClick={(e) => { e.stopPropagation(); handleStartRenameProject(p.id, p.name); }}
                    title="重命名"
                  ><Pencil size={11} /></button>
                  <button
                    className="library-project-action-btn library-project-action-delete"
                    onClick={(e) => { e.stopPropagation(); handleDeleteProject(p.id, p.name); }}
                    title="删除分组"
                  ><Trash2 size={11} /></button>
                </span>
              </button>
            )
          ))}
        </div>}
      </aside>

      {isMobile && mobileSidebarOpen && (
        <button className="mobile-sidebar-backdrop" aria-label="关闭项目分组" onClick={() => setMobileSidebarOpen(false)} />
      )}

      {/* Main: Paper List */}
      <main className="flex-1 flex flex-col overflow-hidden library-main">
        {/* Toolbar */}
        <div className="p-4 border-b flex items-center gap-2 library-toolbar" style={{ borderColor: 'var(--gray-200)' }}>
          <button className="mobile-sidebar-toggle" onClick={() => setMobileSidebarOpen(true)} aria-label="打开项目分组" title="项目分组"><FolderInput size={16} /></button>
          <div className="library-heading"><span>LIBRARY</span><h1>论文库</h1></div>
          <div className="flex-1 flex items-center gap-2">
            <div className="relative flex-1 max-w-md">
              <Search size={14} className="absolute left-2 top-1/2 -translate-y-1/2" style={{ color: 'var(--gray-400)' }} />
              <input
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && handleSearch()}
                placeholder="搜索论文标题..."
                className="w-full pl-7 pr-3 py-1.5 text-xs rounded border outline-none"
                style={{ background: 'var(--gray-0)', borderColor: 'var(--gray-300)' }}
              />
            </div>
            <label className="library-compact-select" title="按处理状态筛选">
              <ListFilter size={13} />
              <select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value)} aria-label="按处理状态筛选">
                <option value="all">全部状态</option>
                <option value="uploaded">待解析</option>
                <option value="ready">已就绪</option>
                <option value="parsed">已解析</option>
                <option value="normalizing">清洗中</option>
                <option value="analyzing">分析中</option>
                <option value="reducing">归纳中</option>
                <option value="parsing">解析中</option>
                <option value="error">出错</option>
              </select>
            </label>
            <label className="library-compact-select">
              <select value={sortMode} onChange={(event) => setSortMode(event.target.value)} aria-label="论文排序">
                <option value="recent">最近添加</option>
                <option value="title">标题排序</option>
                <option value="year">年份排序</option>
                <option value="status">状态排序</option>
              </select>
            </label>
          </div>
          <button
            className={`library-select-toggle${selectionMode ? ' active' : ''}`}
            onClick={() => { setSelectionMode((active) => !active); if (selectionMode) setSelectedIds(new Set()); }}
            aria-pressed={selectionMode}
          >
            <MousePointer2 size={14} />选择
          </button>
          <button
            onClick={() => setShowUpload(true)}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded text-white transition-fast hover:opacity-90"
            style={{ background: 'var(--accent)' }}
          >
            <Upload size={14} />
            上传论文
          </button>
        </div>

        {(selectionMode || selectedIds.size > 0) && (
          <div className="library-selection-bar">
            <button className="library-select-all" onClick={toggleSelectAll}>
              {visiblePapers.length > 0 && visiblePapers.every((paper) => selectedIds.has(paper.id)) ? <CheckSquare2 size={15} /> : <Square size={15} />}
              选择当前结果
            </button>
            <strong>{selectedIds.size ? `已选择 ${selectedIds.size} 篇` : '点击条目或复选框进行选择'}</strong>
            <span className="library-selection-spacer" />
            <select value={targetProjectId} onChange={(event) => setTargetProjectId(event.target.value)} aria-label="目标项目">
              <option value="">移出项目分组</option>
              {projects.map((project) => <option key={project.id} value={project.id}>移动到：{project.name}</option>)}
            </select>
            <button className="library-batch-move" onClick={() => handleMove([...selectedIds], targetProjectId || null)} disabled={!selectedIds.size || moving}>
              {moving ? <Loader2 size={14} className="animate-spin" /> : <FolderInput size={14} />}移动
            </button>
            <button className="library-batch-delete" onClick={handleBatchDelete} disabled={!selectedIds.size || deleting}>
              {deleting ? <Loader2 size={14} className="animate-spin" /> : <Trash2 size={14} />}删除
            </button>
            <button className="library-clear-selection" onClick={clearSelection}>完成</button>
          </div>
        )}

        {/* Paper grid */}
        <div className="flex-1 overflow-y-auto p-6 library-content" style={{ background: 'var(--gray-50)' }}>
          {(error || actionError) && papers.length > 0 && (
            <div className="library-inline-error"><ShieldAlert size={14} /><span>{actionError || error}</span><button onClick={() => { setActionError(''); fetchPapers(filter); }}><RefreshCw size={13} />重试</button></div>
          )}
          {loading && papers.length === 0 ? (
            <div className="paper-grid library-skeleton-grid" aria-label="正在加载论文">
              {[0, 1, 2].map((item) => <div key={item} className="library-paper-skeleton"><span /><span /><span /></div>)}
            </div>
          ) : error && papers.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-full workspace-empty library-error-state" style={{ color: 'var(--gray-400)' }}>
              <ShieldAlert size={42} />
              <p>论文条目暂时无法载入</p>
              <p>{error}</p>
              <button onClick={() => fetchPapers(filter)}><RefreshCw size={14} />重新载入</button>
            </div>
          ) : visiblePapers.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-full workspace-empty" style={{ color: 'var(--gray-400)' }}>
              <FileText size={48} className="mb-3 opacity-30" />
              <p className="text-sm">没有符合条件的论文</p>
              <p className="text-xs mt-1">调整筛选条件，或上传 PDF 开始阅读</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4 gap-4 paper-grid">
              {visiblePapers.map((paper) => (
                <PaperCard
                  key={paper.id}
                  paper={paper}
                  projectName={projects.find((project) => project.id === paper.project_id)?.name || ''}
                  selected={selectedIds.has(paper.id)}
                  selectionMode={selectionMode}
                  renaming={renamingPaperId === paper.id}
                  renameValue={renamingPaperId === paper.id ? renamingPaperTitle : ''}
                  onToggle={() => toggleSelection(paper.id)}
                  onDragStart={(event) => handleDragStart(paper, event)}
                  onDragEnd={() => { setDraggingIds([]); setDropProjectId(null); }}
                  onClick={() => selectionMode ? toggleSelection(paper.id) : navigate(`/paper/${paper.id}`)}
                  onDelete={handleDelete}
                  onStartRename={handleStartRenamePaper}
                  onRenameChange={setRenamingPaperTitle}
                  onConfirmRename={handleConfirmRenamePaper}
                  onCancelRename={handleCancelRenamePaper}
                />
              ))}
            </div>
          )}
        </div>
      </main>

      {/* Upload modal */}
      {showUpload && (
        <div className="fixed inset-0 z-50 flex items-center justify-center" style={{ background: 'rgba(0,0,0,0.4)' }}>
          <div className="rounded-lg p-5 w-96" style={{ background: 'var(--gray-0)' }}>
            <div className="flex items-center justify-between mb-4">
              <h3 className="text-sm font-medium">上传论文</h3>
              <button onClick={() => setShowUpload(false)}><X size={16} style={{ color: 'var(--gray-500)' }} /></button>
            </div>

            <input
              ref={fileInput}
              type="file"
              accept=".pdf"
              multiple
              className="hidden"
              onChange={(e) => handleUpload(e.target.files)}
            />

            <div
              onClick={() => fileInput.current?.click()}
              className="border-2 border-dashed rounded-lg p-8 text-center cursor-pointer transition-fast hover:border-[var(--accent)]"
              style={{ borderColor: 'var(--gray-300)', color: 'var(--gray-500)' }}
            >
              {uploading ? (
                <Loader2 size={24} className="mx-auto animate-spin" />
              ) : (
                <>
                  <Upload size={24} className="mx-auto mb-2" />
                  <p className="text-sm">点击选择 PDF 文件</p>
                  <p className="text-xs mt-1 opacity-60">支持多选批量上传</p>
                </>
              )}
            </div>

            {!pipelineReady && (
              <div className="mt-3 p-3 rounded-lg flex items-start gap-2" style={{ background: 'color-mix(in srgb, var(--amber) 9%, transparent)', color: 'var(--amber)' }}>
                <ShieldAlert size={15} className="shrink-0 mt-0.5" />
                <div className="flex-1"><p className="text-xs font-medium">处理流程尚未配置</p><p className="text-[10px] mt-1 leading-relaxed">需要模型 API Key 和 MinerU Token。</p></div>
                <button onClick={() => navigate('/settings')} className="flex items-center gap-1 text-[10px] font-medium">去设置 <ArrowRight size={11} /></button>
              </div>
            )}
            {uploadError && <p className="mt-3 text-xs" style={{ color: 'var(--danger)' }}>{uploadError}</p>}

            <p className="text-xs mt-3 text-center" style={{ color: 'var(--gray-500)' }}>
              当前项目: {projects.find(p => p.id === filter.project_id)?.name || '未选择'}
            </p>
          </div>
        </div>
      )}

    </div>
  );
}

function PaperCard({ paper, projectName, selected, selectionMode, renaming, renameValue, onToggle, onDragStart, onDragEnd, onClick, onDelete, onStartRename, onRenameChange, onConfirmRename, onCancelRename }: {
  paper: PaperListItem;
  projectName: string;
  selected: boolean;
  selectionMode: boolean;
  renaming: boolean;
  renameValue: string;
  onToggle: () => void;
  onDragStart: (event: React.DragEvent) => void;
  onDragEnd: () => void;
  onClick: () => void;
  onDelete: (id: string, e: React.MouseEvent) => void;
  onStartRename: (id: string, title: string) => void;
  onRenameChange: (value: string) => void;
  onConfirmRename: () => void;
  onCancelRename: () => void;
}) {
  const statusColor = STATUS_COLORS[paper.status] || STATUS_COLORS.default;

  return (
    <div
      onClick={renaming ? undefined : onClick}
      draggable={!renaming}
      onDragStart={onDragStart}
      onDragEnd={onDragEnd}
      className={`rounded-lg border p-3 cursor-pointer transition-fast hover:shadow-sm group paper-library-card${selected ? ' selected' : ''}${selectionMode ? ' selection-mode' : ''}${renaming ? ' is-renaming' : ''}`}
      style={{ background: 'var(--gray-0)', borderColor: 'var(--gray-200)' }}
      aria-selected={selected}
    >
      <div className="flex items-start justify-between paper-library-card-head">
        <button
          className="paper-card-selector"
          onClick={(event) => { event.stopPropagation(); onToggle(); }}
          aria-label={selected ? '取消选择论文' : '选择论文'}
          title={selected ? '取消选择' : '选择'}
        >
          {selected ? <CheckSquare2 size={16} /> : <Square size={16} />}
        </button>
        <div className="flex-1 min-w-0">
          {renaming ? (
            <div className="paper-inline-rename" onClick={(event) => event.stopPropagation()}>
              <input
                autoFocus
                value={renameValue}
                onChange={(event) => onRenameChange(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') onConfirmRename();
                  if (event.key === 'Escape') onCancelRename();
                }}
                aria-label="论文标题"
              />
              <div className="paper-inline-rename-actions">
                <button className="confirm" onClick={onConfirmRename} disabled={!renameValue.trim()} title="保存重命名"><Check size={13} />保存</button>
                <button onClick={onCancelRename} title="取消重命名"><X size={13} />取消</button>
              </div>
            </div>
          ) : (
            <>
              <h3 className="text-sm font-medium paper-library-title" style={{ color: 'var(--gray-800)' }}>
                {paper.title || paper.original_file_name || '未命名论文'}
              </h3>
              {paper.title_zh && paper.title_zh !== paper.title && (
            <p className="text-xs mt-0.5 paper-library-title-zh" style={{ color: 'var(--gray-500)' }}>{paper.title_zh}</p>
              )}
            </>
          )}
        </div>
        <div className="paper-card-actions">
          {!renaming && <GripVertical size={15} className="paper-card-drag-handle" aria-label="拖拽论文到项目分组" />}
          {!renaming && <button onClick={(e) => { e.stopPropagation(); onStartRename(paper.id, paper.title || paper.original_file_name || ''); }} title="重命名"><Pencil size={13} /></button>}
          <button onClick={(e) => onDelete(paper.id, e)} title="删除"><Trash2 size={13} /></button>
        </div>
      </div>

      <div className="mt-2 flex items-center gap-2 text-[10px] paper-library-meta" style={{ color: 'var(--gray-500)' }}>
        <span className="flex items-center gap-1">
          <span className="w-1.5 h-1.5 rounded-full" style={{ background: statusColor }} />
          {STATUS_LABELS[paper.status] || paper.status}
        </span>
        {paper.authors?.length > 0 && <span className="truncate">{paper.authors[0]}{paper.authors.length > 1 ? ' 等' : ''}</span>}
        {paper.year && <span>{paper.year}</span>}
        {projectName && <span className="paper-project-badge">{projectName}</span>}
      </div>

      <div className="mt-2 flex flex-wrap gap-1 paper-library-tags">
        {paper.domain_tags?.slice(0, 3).map((tag) => (
          <span key={tag} className="px-1.5 py-0.5 text-[10px] rounded" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>
            {tag}
          </span>
        ))}
      </div>
    </div>
  );
}
