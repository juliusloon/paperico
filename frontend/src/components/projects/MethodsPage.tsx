import { useEffect, useMemo, useState } from 'react';
import { Layers, Search, PanelLeft, PanelLeftClose, X } from 'lucide-react';
import { api } from '../../api/client';
import { useMediaQuery } from '../../hooks/useMediaQuery';
import type { MethodIndexItem } from '../../api/types';

const CATEGORY_LABELS: Record<string, string> = {
  ML_MODEL: '机器学习模型',
  ALGORITHM: '算法/优化方法',
  INSTRUMENT_METHOD: '表征/检测方法',
  DATASET_BENCHMARK: '数据集/基准',
  METRIC: '评价指标',
  CHEMISTRY: '反应类型/试剂',
  SOFTWARE_TOOL: '软件/工具',
  OTHER: '其他',
};

const CATEGORY_COLORS: Record<string, string> = {
  ML_MODEL: '#2563eb',
  ALGORITHM: '#7c3aed',
  INSTRUMENT_METHOD: '#0891b2',
  DATASET_BENCHMARK: '#059669',
  METRIC: '#d97706',
  CHEMISTRY: '#dc2626',
  SOFTWARE_TOOL: '#4f46e5',
  OTHER: '#6b7280',
};

export default function MethodsPage() {
  const [items, setItems] = useState<MethodIndexItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState('');
  const [categoryFilter, setCategoryFilter] = useState('');
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const isMobile = useMediaQuery('(max-width: 760px)');
  const [mobileSidebarOpen, setMobileSidebarOpen] = useState(false);
  const effectiveSidebarCollapsed = sidebarCollapsed && !isMobile;

  const selectCategory = (category: string) => {
    setCategoryFilter(category);
    setMobileSidebarOpen(false);
  };

  useEffect(() => {
    let active = true;
    setLoading(true);
    api.library.methods({ q: query || undefined }).then((data) => {
      if (active) setItems(data);
    }).catch((error) => console.error('Failed to load methods:', error)).finally(() => {
      if (active) setLoading(false);
    });
    return () => { active = false; };
  }, []);

  const handleSearch = async () => {
    setLoading(true);
    try {
      const data = await api.library.methods({
        category: categoryFilter || undefined,
        q: query || undefined,
      });
      setItems(data);
    } catch (e) {
      console.error('Failed to load methods:', e);
    } finally {
      setLoading(false);
    }
  };

  // Compute category counts from the full item list
  const categoryCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const item of items) {
      counts[item.category] = (counts[item.category] || 0) + 1;
    }
    return counts;
  }, [items]);

  const categories = useMemo(() => {
    return Object.entries(CATEGORY_LABELS)
      .filter(([key]) => categoryCounts[key])
      .map(([key, label]) => ({ key, label, count: categoryCounts[key] }));
  }, [categoryCounts]);

  const totalMethods = items.length;

  const filteredItems = useMemo(() => {
    if (!categoryFilter) return items;
    return items.filter((item) => item.category === categoryFilter);
  }, [items, categoryFilter]);

  return (
    <div className="h-full flex methods-page">
      {/* Sidebar: Categories */}
      <aside
        className={`w-56 shrink-0 border-r flex flex-col overflow-hidden methods-sidebar${effectiveSidebarCollapsed ? ' collapsed' : ''}${mobileSidebarOpen ? ' mobile-open' : ''}`}
        style={{ background: 'var(--gray-50)', borderColor: 'var(--gray-200)' }}
      >
        <div className="p-3 border-b flex items-center justify-between methods-sidebar-header" style={{ borderColor: 'var(--gray-200)' }}>
          <span className="text-xs font-medium" style={{ color: 'var(--gray-600)' }}>实体类别</span>
          <button
            onClick={isMobile ? () => setMobileSidebarOpen(false) : () => setSidebarCollapsed(!sidebarCollapsed)}
            title={isMobile ? '关闭实体类别' : sidebarCollapsed ? '展开类别' : '收起类别'}
          >
            {isMobile ? <X size={14} /> : sidebarCollapsed ? <PanelLeft size={14} /> : <PanelLeftClose size={14} />}
          </button>
        </div>

        {!effectiveSidebarCollapsed && (
          <div className="flex-1 overflow-y-auto methods-category-list">
            <button
              onClick={() => selectCategory('')}
              className={`w-full text-left px-3 py-2 text-xs transition-fast flex items-center justify-between methods-category-item${!categoryFilter ? ' is-active' : ''}`}
              style={{
                color: !categoryFilter ? 'var(--accent)' : 'var(--gray-700)',
                background: !categoryFilter ? 'var(--accent-soft)' : 'transparent',
              }}
            >
              <span>全部方法</span>
              <span className="text-[10px] opacity-60">{totalMethods}</span>
            </button>
            {categories.map((cat) => (
              <button
                key={cat.key}
                onClick={() => selectCategory(cat.key)}
                className={`w-full text-left px-3 py-2 text-xs transition-fast flex items-center justify-between methods-category-item${categoryFilter === cat.key ? ' is-active' : ''}`}
                style={{
                  color: categoryFilter === cat.key ? 'var(--accent)' : 'var(--gray-700)',
                  background: categoryFilter === cat.key ? 'var(--accent-soft)' : 'transparent',
                }}
              >
                <span className="truncate flex items-center gap-2">
                  <span className="w-2 h-2 rounded-full shrink-0" style={{ background: CATEGORY_COLORS[cat.key] || CATEGORY_COLORS.OTHER }} />
                  {cat.label}
                </span>
                <span className="text-[10px] opacity-60">{cat.count}</span>
              </button>
            ))}
          </div>
        )}
      </aside>

      {isMobile && mobileSidebarOpen && (
        <button className="mobile-sidebar-backdrop" aria-label="关闭实体类别" onClick={() => setMobileSidebarOpen(false)} />
      )}

      {/* Main: Method Cards */}
      <main className="flex-1 flex flex-col overflow-hidden methods-main">
        {/* Toolbar */}
        <div className="p-4 border-b flex items-center gap-3 methods-toolbar" style={{ borderColor: 'var(--gray-200)' }}>
          <button className="mobile-sidebar-toggle" onClick={() => setMobileSidebarOpen(true)} aria-label="打开实体类别" title="实体类别"><Layers size={16} /></button>
          <div className="methods-heading"><span>METHOD INDEX</span><h1>方法索引</h1></div>
          <div className="flex-1 flex items-center gap-2">
            <div className="relative flex-1 max-w-md">
              <Search size={14} className="absolute left-2 top-1/2 -translate-y-1/2" style={{ color: 'var(--gray-400)' }} />
              <input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && handleSearch()}
                placeholder="搜索方法名称..."
                className="w-full pl-7 pr-3 py-1.5 text-xs rounded border outline-none"
                style={{ background: 'var(--gray-0)', borderColor: 'var(--gray-300)', color: 'var(--gray-800)' }}
              />
            </div>
            <button
              onClick={handleSearch}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded text-white transition-fast hover:opacity-90"
              style={{ background: 'var(--accent)' }}
            >
              搜索
            </button>
          </div>
        </div>

        {/* Method grid */}
        <div className="flex-1 overflow-y-auto p-6 methods-content" style={{ background: 'var(--gray-50)' }}>
          {loading ? (
            <div className="methods-grid methods-skeleton-grid" aria-label="正在加载方法">
              {[0, 1, 2, 3, 4, 5].map((item) => (
                <div key={item} className="methods-skeleton-card">
                  <span />
                  <span />
                  <span />
                </div>
              ))}
            </div>
          ) : filteredItems.length === 0 ? (
            <div className="flex flex-col items-center justify-center h-full workspace-empty methods-empty" style={{ color: 'var(--gray-400)' }}>
              <Layers size={46} className="mb-3 opacity-30" />
              <p>暂无方法索引</p>
              <p>上传并分析论文后，方法实体将自动归集于此</p>
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4 gap-4 methods-grid">
              {filteredItems.map((item) => (
                <MethodCard key={item.canonical_key} item={item} />
              ))}
            </div>
          )}
        </div>
      </main>
    </div>
  );
}

function MethodCard({ item }: { item: MethodIndexItem }) {
  const [expanded, setExpanded] = useState(false);
  const catColor = CATEGORY_COLORS[item.category] || CATEGORY_COLORS.OTHER;

  return (
    <div
      className="rounded-lg border p-3 cursor-pointer transition-fast hover:shadow-sm method-card"
      style={{ borderColor: 'var(--gray-200)', background: 'var(--gray-0)' }}
      onClick={() => setExpanded(!expanded)}
    >
      <div className="flex items-start justify-between">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2">
            <span className="w-2 h-2 rounded-full shrink-0" style={{ background: catColor }} />
            <h3 className="text-sm font-medium method-card-title" style={{ color: 'var(--gray-800)' }}>{item.name}</h3>
          </div>
          {item.definition_zh && (
            <p className="text-xs mt-1 ml-4 method-card-definition" style={{ color: 'var(--gray-600)' }}>{item.definition_zh}</p>
          )}
        </div>
        <div className="flex flex-col items-end gap-1 shrink-0 ml-2">
          <span className="text-[10px] px-1.5 py-0.5 rounded" style={{ background: catColor + '20', color: catColor }}>
            {CATEGORY_LABELS[item.category] || item.category}
          </span>
          <span className="text-[10px]" style={{ color: 'var(--gray-500)' }}>
            {item.papers.length} 篇论文
          </span>
        </div>
      </div>

      {expanded && (
        <div className="mt-2 pt-2 border-t space-y-1" style={{ borderColor: 'var(--gray-200)' }}>
          {item.papers.map((p) => (
            <a
              key={p.paper_id}
              href={`/paper/${p.paper_id}`}
              className="flex items-center gap-2 text-xs py-1 px-2 rounded transition-fast hover:opacity-80"
              style={{ color: 'var(--accent)', background: 'var(--accent-soft)' }}
              onClick={(e) => e.stopPropagation()}
            >
              <span className="truncate flex-1">{p.title}</span>
              <span className="text-[10px] opacity-60">{p.block_ids.length} 处</span>
            </a>
          ))}
        </div>
      )}
    </div>
  );
}
