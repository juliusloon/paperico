#!/bin/bash
# Paperico — start the backend (FastAPI).
#
# The native macOS app (macos/) connects to this backend; see README.md.
#
# Usage: ./start.sh
#   First run bootstraps everything: creates backend/.venv and installs
#   Python dependencies, then starts the server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_HOST="0.0.0.0"   # LAN-visible so the app can connect from another machine

if ! command -v python3 >/dev/null; then
  echo "error: python3 (3.11+) is required" >&2; exit 1
fi

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

trap 'kill $BACKEND_PID 2>/dev/null; exit 0' SIGINT SIGTERM

echo ""
echo "========================================="
echo "  Paperico backend is running"
echo "  API:        http://127.0.0.1:8000"
echo "  API docs:   http://127.0.0.1:8000/docs"
echo "  LAN:        http://<this-machine-LAN-IP>:8000"
echo "  Ctrl+C to stop"
echo "========================================="
echo ""

wait
