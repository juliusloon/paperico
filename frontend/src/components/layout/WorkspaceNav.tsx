import { useEffect, useRef, useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import {
  Feather, BookOpen, ChevronDown, House, Layers3, Library, Moon, PanelLeft,
  PanelLeftClose, Settings, Sun,
} from 'lucide-react';
import { useAppStore } from '../../stores';

type WorkspaceNavProps = {
  collapsed?: boolean;
  currentPaperId?: string;
  onToggleOutline?: () => void;
};

export default function WorkspaceNav({ collapsed = false, currentPaperId, onToggleOutline }: WorkspaceNavProps) {
  const location = useLocation();
  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const { theme, setTheme } = useAppStore();
  const isDark = theme === 'dark' || (theme === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);

  useEffect(() => {
    const close = (event: PointerEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) setOpen(false);
    };
    window.addEventListener('pointerdown', close);
    return () => window.removeEventListener('pointerdown', close);
  }, []);

  const readerPaperId = currentPaperId || localStorage.getItem('paperico:last-paper');
  const pages = [
    { to: '/', label: '首页', icon: House },
    { to: '/library', label: '论文库', icon: Library },
    { to: '/methods', label: '方法索引', icon: Layers3 },
    ...(readerPaperId ? [{ to: `/paper/${readerPaperId}`, label: '阅读器', icon: BookOpen }] : []),
    { to: '/settings', label: '设置', icon: Settings },
  ];
  const isActive = (to: string) => to === '/' ? location.pathname === '/' : location.pathname.startsWith(to);

  return (
    <div ref={menuRef} className={`reader-local-nav page-desk-nav${collapsed ? ' collapsed' : ''}`}>
      <button className="reader-brand-button" onClick={() => setOpen((value) => !value)} aria-expanded={open} title="展开工作台导航">
        <span className="reader-brand-mark"><Feather size={16} /></span>
        <span className="reader-brand-copy"><strong>Paperico</strong><small>Research desk</small></span>
        <ChevronDown className={open ? 'open' : ''} size={14} />
      </button>
      <span className="reader-nav-spacer" />
      {!collapsed && (
        <button className="reader-nav-action" onClick={() => setTheme(isDark ? 'light' : 'dark')} title={isDark ? '切换亮色' : '切换暗色'}>
          {isDark ? <Sun size={15} /> : <Moon size={15} />}
        </button>
      )}
      {onToggleOutline && (
        <button className="reader-nav-action" onClick={onToggleOutline} title={collapsed ? '展开结构目录' : '收起结构目录'}>
          {collapsed ? <PanelLeft size={16} /> : <PanelLeftClose size={16} />}
        </button>
      )}
      {open && (
        <nav className="reader-page-menu" aria-label="Paperico 页面">
          {pages.map(({ to, label, icon: Icon }) => (
            <Link key={to} to={to} className={isActive(to) ? 'active' : ''} onClick={() => setOpen(false)}>
              <Icon size={15} /><span>{label}</span>{isActive(to) && <small>当前</small>}
            </Link>
          ))}
        </nav>
      )}
    </div>
  );
}
