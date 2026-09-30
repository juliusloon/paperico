#!/bin/bash
# Paperico — start the backend (FastAPI).
#
# The native macOS app (macos/) connects to this backend; see README.md.
#
# Usage: ./start.sh [--app-data]
#   First run bootstraps everything: creates backend/.venv and installs
#   Python dependencies, then starts the server.
#
#   --app-data  Store user data (database, PDFs, extracts) in
#               ~/Library/Application Support/Paperico/ instead of the
#               repository folder — the "installed app" layout. An existing
#               repository database + storage are copied over on first use.
#
#   BACKEND_PORT=8000  Override the listen port.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_HOST="0.0.0.0"   # LAN-visible so the app can connect from another machine
BACKEND_PORT="${BACKEND_PORT:-8000}"

APP_DATA=0
for arg in "$@"; do
  case "$arg" in
    --app-data) APP_DATA=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

if ! command -v python3 >/dev/null; then
  echo "error: python3 (3.11+) is required" >&2; exit 1
fi

DATA_ENV=()
if [ "$APP_DATA" -eq 1 ]; then
  DATA_DIR="$HOME/Library/Application Support/Paperico"
  mkdir -p "$DATA_DIR/storage"

  # First use: bring along existing repository data (database + PDF storage,
  # including the .paperico.key that unlocks stored credentials).
  if [ ! -f "$DATA_DIR/paperico.db" ] && [ -f "$SCRIPT_DIR/backend/paperico.db" ]; then
    echo "Migrating existing repository data into $DATA_DIR …"
    cp "$SCRIPT_DIR/backend/paperico.db" "$DATA_DIR/paperico.db"
    if [ -d "$SCRIPT_DIR/backend/app/storage" ]; then
      cp -R "$SCRIPT_DIR/backend/app/storage/." "$DATA_DIR/storage/"
    fi
  fi

  # SQLAlchemy URLs percent-encode the path ("Application Support" → %20).
  # Note the four slashes: sqlite absolute paths need "sqlite:////abs/path".
  DATA_URL="${DATA_DIR// /%20}"
  # Real env vars win over backend/.env in pydantic-settings.
  export PAPERICO_STORAGE_ROOT="$DATA_DIR/storage"
  export PAPERICO_DATABASE_URL="sqlite+aiosqlite:///${DATA_URL}/paperico.db"
  echo "Data directory: $DATA_DIR"
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

echo "Starting backend on http://127.0.0.1:$BACKEND_PORT …"
.venv/bin/python -m uvicorn app.main:app \
  --host "$BACKEND_HOST" --port "$BACKEND_PORT" --reload &
BACKEND_PID=$!

trap 'kill $BACKEND_PID 2>/dev/null; exit 0' SIGINT SIGTERM

echo ""
echo "========================================="
echo "  Paperico backend is running"
echo "  API:        http://127.0.0.1:$BACKEND_PORT"
echo "  API docs:   http://127.0.0.1:$BACKEND_PORT/docs"
echo "  LAN:        http://<this-machine-LAN-IP>:$BACKEND_PORT"
if [ "$APP_DATA" -eq 1 ]; then
  echo "  User data:  $DATA_DIR"
else
  echo "  User data:  backend/ (repo mode; use --app-data for ~/Library)"
fi
echo "  Ctrl+C to stop"
echo "========================================="
echo ""

wait
