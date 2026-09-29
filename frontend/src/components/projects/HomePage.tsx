import { useEffect } from 'react';
import { ArrowRight, BookOpen, BrainCircuit, FileSearch2, Library, Sparkles } from 'lucide-react';
import { Link, useNavigate } from 'react-router-dom';
import { usePapersStore, useProjectsStore } from '../../stores';

export default function HomePage() {
  const navigate = useNavigate();
  const { papers, fetch: fetchPapers } = usePapersStore();
  const { projects, fetch: fetchProjects } = useProjectsStore();

  useEffect(() => {
    fetchPapers();
    fetchProjects();
  }, [fetchPapers, fetchProjects]);

  const readyCount = papers.filter((paper) => paper.status === 'ready').length;
  const recent = papers.slice(0, 4);

  return (
    <main className="home-page">
      <section className="home-hero">
        <div className="hero-copy">
          <p className="eyebrow"><Sparkles size={13} /> PAPER READING WORKBENCH</p>
          <h1>将读 PDF 变成<br /><em>真正理解论文。</em></h1>
          <p className="hero-lede">上传 PDF，自动拆解文本图表，生成双语阅读与逻辑链，并在原文证据范围内持续追问。</p>
          <div className="hero-actions">
            <Link className="primary-action" to="/library">打开论文库 <ArrowRight size={15} /></Link>
            <Link className="secondary-action" to="/settings">检查 API 配置</Link>
          </div>
        </div>
        <div className="hero-orbit" aria-hidden="true">
          <div className="orbit-paper">
            <span className="orbit-index">P / 01</span>
            <div className="orbit-lines"><i /><i /><i /><i /><i /></div>
            <div className="orbit-rail"><b /><b /><b /></div>
          </div>
          <div className="orbit-badge">结构化<br />精读</div>
        </div>
      </section>

      <section className="home-metrics" aria-label="工作台概览">
        <Metric icon={Library} value={papers.length} label="篇论文" />
        <Metric icon={BookOpen} value={readyCount} label="已完成解析" />
        <Metric icon={BrainCircuit} value={projects.length} label="个研究项目" />
      </section>

      <section className="home-lower-grid">
        <div className="home-panel recent-panel">
          <div className="panel-heading">
            <div><span className="section-kicker">RECENT</span><h2>继续阅读</h2></div>
            <Link to="/library">查看全部 <ArrowRight size={13} /></Link>
          </div>
          {recent.length ? (
            <div className="recent-list">
              {recent.map((paper, index) => (
                <button key={paper.id} onClick={() => navigate(`/paper/${paper.id}`)}>
                  <span className="recent-number">{String(index + 1).padStart(2, '0')}</span>
                  <span className="recent-title"><strong>{paper.title || paper.original_file_name}</strong><small>{paper.status === 'ready' ? paper.tldr || '已完成解析' : '正在准备阅读内容'}</small></span>
                  <span className={`status-dot ${paper.status}`} />
                  <ArrowRight size={14} />
                </button>
              ))}
            </div>
          ) : (
            <div className="home-empty"><FileSearch2 size={28} /><p>还没有论文。前往论文库上传第一份 PDF。</p></div>
          )}
        </div>

        <aside className="home-panel workflow-panel">
          <span className="section-kicker">WORKFLOW</span>
          <h2>一条连贯的阅读路径</h2>
          <ol>
            <li><b>01</b><span><strong>文件拆解</strong><small>解析文本与图表，重构成连贯的流式阅读版式。</small></span></li>
            <li><b>02</b><span><strong>提炼逻辑</strong><small>分析论文叙述逻辑，生成与阅读进度同步的逻辑链。</small></span></li>
            <li><b>03</b><span><strong>证据问答</strong><small>与论文解析得到的丰富背景进行直接对话。</small></span></li>
          </ol>
        </aside>
      </section>
    </main>
  );
}

function Metric({ icon: Icon, value, label }: { icon: typeof Library; value: number; label: string }) {
  return <div className="metric"><Icon size={17} /><strong>{value}</strong><span>{label}</span></div>;
}
