import { useLocation } from 'react-router-dom';
import WorkspaceNav from './WorkspaceNav';

export default function TopBar() {
  const location = useLocation();
  if (location.pathname.startsWith('/paper/')) return null;
  const isHome = location.pathname === '/';
  return (
    <header className={`page-nav-slot${isHome ? ' home-nav-slot' : ' workspace-nav-slot'}`}>
      <WorkspaceNav />
    </header>
  );
}
