import { Component, useEffect } from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import { useSettingsStore } from './stores';
import TopBar from './components/layout/TopBar';
import LibraryPage from './components/projects/LibraryPage';
import ReaderPage from './components/reader/ReaderPage';
import SettingsPage from './components/settings/SettingsPage';
import MethodsPage from './components/projects/MethodsPage';
import HomePage from './components/projects/HomePage';

export default function App() {
  const fetchSettings = useSettingsStore((s) => s.fetch);

  useEffect(() => {
    fetchSettings();
  }, [fetchSettings]);

  return (
    <div className="relative h-screen flex flex-col overflow-hidden" style={{ background: 'var(--app-base, var(--gray-0))', color: 'var(--gray-900)' }}>
      <TopBar />
      <div className="flex-1 overflow-hidden">
        <PageErrorBoundary>
          <Routes>
            <Route path="/" element={<HomePage />} />
            <Route path="/library" element={<LibraryPage />} />
            <Route path="/paper/:paperId" element={<ReaderPage />} />
            <Route path="/settings" element={<SettingsPage />} />
            <Route path="/methods" element={<MethodsPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </PageErrorBoundary>
      </div>
    </div>
  );
}

class PageErrorBoundary extends Component<{ children: React.ReactNode }, { error: Error | null }> {
  state = { error: null as Error | null };
  static getDerivedStateFromError(error: Error) { return { error }; }
  render() {
    if (this.state.error) return <div className="reader-state"><span>页面加载失败：{this.state.error.message}</span><button className="secondary-action" onClick={() => window.location.reload()}>重新加载</button></div>;
    return this.props.children;
  }
}
