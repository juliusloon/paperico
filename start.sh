#!/bin/bash
# Paperico — start the backend (FastAPI) and web client (Vite) together.
#
# Usage: ./start.sh [--host HOST]
#   First run bootstraps everything: creates backend/.venv, installs Python
#   and npm dependencies, then starts both processes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_HOST="0.0.0.0"   # LAN-visible so native clients on other devices can connect

# ── Preflight ────────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null; then
  echo "error: python3 (3.11+) is required" >&2; exit 1
fi
if ! command -v node >/dev/null; then
  echo "error: node (20+) is required for the web client" >&2; exit 1
fi

# ── Backend ──────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR/backend"
if [ ! -x .venv/bin/python ]; then
  echo "Creating backend virtualenv (.venv)…"
  python3 -m venv .venv
fi
if ! .venv/bin/python -c "import uvicorn" >/dev/null 2>&1; then
  echo "Installing backend dependencies…"
  if command -v uv >/dev/null; then
    uv pip install --python .venv/bin/python -e .
  else
    .venv/bin/pip install -e .
  fi
fi

echo "Starting backend on http://127.0.0.1:8000 …"
.venv/bin/python -m uvicorn app.main:app --host "$BACKEND_HOST" --port 8000 --reload &
BACKEND_PID=$!

# ── Frontend ─────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR/frontend"
if [ ! -d node_modules ]; then
  echo "Installing web client dependencies…"
  npm ci
fi

echo "Starting web client on http://127.0.0.1:5173 …"
npm run dev -- --host "$BACKEND_HOST" &
FRONTEND_PID=$!

trap 'kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit 0' SIGINT SIGTERM

echo ""
echo "========================================="
echo "  Paperico is running"
echo "  Web client: http://127.0.0.1:5173"
echo "  Backend:    http://127.0.0.1:8000"
echo "  API docs:   http://127.0.0.1:8000/docs"
echo "  LAN:        http://<this-machine-LAN-IP>:5173"
echo "  Ctrl+C to stop"
echo "========================================="
echo ""

wait
